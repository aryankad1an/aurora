import Foundation
import Observation
import UIKit

/// Sends mails in the background, one at a time, spaced out.
///
/// Sending used to happen inside the send sheet: you tapped Send All and then sat
/// on a progress bar until the last mail went out, unable to use the app, and a
/// hundred near-identical mails left in a tight loop. This moves the work behind
/// the UI — the sheet closes the moment you confirm, and the queue drains at a
/// deliberate pace while you carry on.
///
/// The pacing is the point, not a side effect. A burst of identical mail from a
/// consumer Gmail account is the clearest spam signature there is, and the damage
/// lands on the sender's own domain reputation — every *future* mail, not just
/// this batch.
///
/// The queue holds no references to the auth or data stores; `sender` and
/// `onRecord` are supplied by `RootView`, which owns both.
enum MailQueueError: LocalizedError {
    case noTransport

    var errorDescription: String? { "No mail account is connected." }
}

@Observable
@MainActor
final class MailQueue {

    /// One mail, already rendered — the queue never re-renders from a template,
    /// so what was reviewed on screen is exactly what goes out.
    struct Mail: Identifiable {
        let id: Contact.ID
        let recipient: String
        let displayName: String
        let subject: String
        let body: String
    }

    struct Outcome {
        let sent: Int
        let failed: [String]
        /// Why the run stopped short, when it was for a reason every mail shared
        /// (the Gmail session ended) rather than one address failing.
        var stoppedBecause: String? = nil
    }

    /// What the transport reports back about a delivered mail. The thread id is
    /// how a reply is recognised later, so it's carried from the send all the way
    /// into the stored record rather than looked up afterwards.
    struct Delivery {
        let messageID: String
        let threadID: String
    }

    /// Gap between sends. Fast enough to clear a large batch in a couple of
    /// minutes, slow enough not to look automated: Gmail's API allows roughly two
    /// sends a second, but the limit that matters is the spam heuristic, not the
    /// quota.
    private static let spacing = Duration.milliseconds(1200)
    /// Random slack either side of `spacing`, so the send pattern isn't perfectly
    /// periodic the way only a machine's would be.
    private static let jitter = 400
    /// How many delivered mails are held before they're written to the send
    /// history. A run is recorded as it goes, not only at the end: if iOS ends
    /// the app mid-run, at most this many sent mails go unrecorded — and an
    /// unrecorded send is a contact the app will offer to mail a second time.
    private static let recordEvery = 5

    private(set) var total = 0
    private(set) var sent = 0
    private(set) var failed: [String] = []
    private(set) var isRunning = false
    /// Stop was tapped and the mail already in flight is finishing.
    private(set) var isStopping = false

    /// Set when a run finishes so the UI can report it. Cleared by `acknowledge()`.
    private(set) var outcome: Outcome?

    /// Delivers one mail and reports what the provider called it. Injected so the
    /// queue stays independent of Gmail auth.
    var sender: ((Mail, String) async throws -> Delivery?)?
    /// Records delivered mails in the send history, a few at a time (see
    /// `recordEvery`), and says whether the write landed. Ones that didn't are
    /// offered again with the next batch.
    var onRecord: (([Contact.ID: SentMail]) async -> Bool)?

    private var pending: [Mail] = []
    /// Mails confirmed after Stop, while the stopped run finishes the one mail
    /// already in flight. They start the next run as soon as it ends — joining
    /// the stopping one would have dropped them without a word.
    private var nextRun: [Mail] = []
    private var stoppedBecause: String?
    private var fromName = ""
    private var assertion = UIBackgroundTaskIdentifier.invalid

    /// True whenever there's something for the UI to show — mid-run, or a result
    /// the user hasn't acknowledged yet.
    var isActive: Bool { isRunning || outcome != nil }

    var completed: Int { sent + failed.count }

    var progress: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    // MARK: - Queueing

    /// Add mails to the queue, starting a run if one isn't already going.
    ///
    /// Mails queued while a run is in flight join that run rather than starting a
    /// competing one — two loops sending at once would defeat the spacing.
    func enqueue(_ mails: [Mail], fromName: String) {
        guard !mails.isEmpty else { return }
        self.fromName = fromName

        if isStopping {
            nextRun.append(contentsOf: mails)
        } else if isRunning {
            pending.append(contentsOf: mails)
            total += mails.count
        } else {
            start(mails)
        }
    }

    /// Stop after the in-flight mail. Anything already sent stays sent.
    ///
    /// Emptying the queue is the whole mechanism: the loop runs out of mail and
    /// ends. It used to cancel the run's task, and cancellation reaches into the
    /// Gmail request already in flight — a mail Gmail may already have accepted
    /// was aborted client-side, counted as failed and never recorded, so the app
    /// would offer to mail that person again.
    func cancel() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        pending = []
    }

    /// Dismiss a finished run's result.
    func acknowledge() {
        outcome = nil
        total = 0
        sent = 0
        failed = []
    }

    // MARK: - Draining

    private func start(_ mails: [Mail]) {
        pending = mails
        total = mails.count
        sent = 0
        failed = []
        stoppedBecause = nil
        outcome = nil
        isRunning = true
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        beginAssertion()
        defer { endAssertion() }

        var records: [Contact.ID: SentMail] = [:]

        while !pending.isEmpty {
            let mail = pending.removeFirst()
            do {
                // No transport means nothing was delivered. Recording these as
                // sent would mark a whole batch of contacts as mailed without a
                // single mail leaving the account.
                guard let sender else { throw MailQueueError.noTransport }
                let delivery = try await sender(mail, fromName)
                records[mail.id] = SentMail(subject: mail.subject, body: mail.body,
                                            gmailMessageID: delivery?.messageID,
                                            gmailThreadID: delivery?.threadID)
                sent += 1
            } catch let error as GmailAuthError where error.endsRun {
                // Every mail after this one would fail the same way, a second
                // and a bit apart. Stop, and count the rest as not sent.
                failed.append(mail.displayName)
                failed.append(contentsOf: pending.map(\.displayName))
                pending = []
                stoppedBecause = error.localizedDescription
            } catch {
                failed.append(mail.displayName)
            }

            if records.count >= Self.recordEvery {
                await record(&records)
            }
            if !pending.isEmpty {
                try? await Task.sleep(for: Self.spacing + .milliseconds(Int.random(in: -Self.jitter...Self.jitter)))
            }
        }

        // Record even a stopped run's successes — those mails really were sent,
        // and losing them would offer to re-send people who've already been mailed.
        await record(&records)

        isRunning = false
        isStopping = false
        outcome = Outcome(sent: sent, failed: failed, stoppedBecause: stoppedBecause)

        if !nextRun.isEmpty {
            let next = nextRun
            nextRun = []
            start(next)
        }
    }

    /// Write what's been delivered so far to the send history. Kept for the next
    /// attempt if the write fails; `onRecord` has already said why.
    private func record(_ records: inout [Contact.ID: SentMail]) async {
        guard !records.isEmpty, let onRecord else { return }
        if await onRecord(records) { records = [:] }
    }

    // MARK: - Background execution

    /// Ask for a few extra seconds if the app is backgrounded mid-run. This isn't
    /// a guarantee of finishing: once iOS suspends the app the loop simply stops
    /// awaiting and picks up again on return, which is why the UI tells the user
    /// the queue continues when they come back rather than promising delivery.
    ///
    /// The time running out has to be answered by handing the assertion back.
    /// An app that holds one past its expiry isn't suspended, it's terminated —
    /// which used to take the run's unrecorded sends down with it.
    private func beginAssertion() {
        assertion = UIApplication.shared.beginBackgroundTask(withName: "MailQueue") { [weak self] in
            MainActor.assumeIsolated { self?.endAssertion() }
        }
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }
}
