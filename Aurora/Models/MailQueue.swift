import Foundation
import Observation
import UIKit

/// Sends mail in the background, one at a time, spaced out — and keeps every
/// batch on disk until it's done, so none is lost to the app closing.
///
/// A batch is saved as templates plus people (see `MailBatch`), and each mail is
/// written only as it's about to go: a batch of hundreds costs a few hundred
/// bytes a person to hold, and the compose screen never has to write them all.
///
/// The pacing is the point, not a side effect. A burst of identical mail from a
/// consumer Gmail account is the clearest spam signature there is, and the damage
/// lands on the sender's own domain reputation — every *future* mail, not just
/// this batch.
///
/// **Surviving a close.** A mail is saved as `sending` before it's handed to
/// Gmail and as `sent` once Gmail answers. A mail found still `sending` when the
/// app opens was cut off mid-request: Gmail may or may not have it. Rather than
/// guess — a guess either way is a person mailed twice or one never mailed — its
/// Sent mail is searched (`verifier`), and the answer decides. Batches found
/// half-sent come back paused, for the user to resume.
///
/// **Scheduling.** A scheduled batch waits for its time. iOS won't run the app
/// at a given moment, so a notification is left with the system instead
/// (`ScheduledMailNotifier`); once the time has come the batch is `due`, and the
/// app asks — with a summary of what's going — before it sends.
///
/// The queue holds no references to the auth or data stores; `sender`,
/// `verifier` and `onRecord` are supplied by `RootView`, which owns both.
enum MailQueueError: LocalizedError {
    case noTransport

    var errorDescription: String? { "No mail account is connected." }
}

@Observable
@MainActor
final class MailQueue {

    /// What the transport reports back about a delivered mail. The thread id is
    /// how a reply is recognised later, so it's carried from the send all the way
    /// into the stored record rather than looked up afterwards.
    struct Delivery {
        let messageID: String
        let threadID: String
    }

    /// How the last run ended, for the shelf to report.
    struct Outcome {
        let batchID: UUID
        let sent: Int
        let failed: [String]
        /// Why the run stopped short, when it was for a reason every mail shared
        /// (the Gmail session ended) rather than one address failing.
        var stoppedBecause: String? = nil
        /// Stopped with mail still to go — by Pause, or by `stoppedBecause`.
        var isPaused = false
    }

    /// Gap between sends. Fast enough to clear a large batch in a few minutes,
    /// slow enough not to look automated: Gmail's API allows roughly two sends a
    /// second, but the limit that matters is the spam heuristic, not the quota.
    private static let spacing = Duration.milliseconds(1200)
    /// Random slack either side of `spacing`, so the send pattern isn't perfectly
    /// periodic the way only a machine's would be.
    private static let jitter = 400
    /// How many delivered mails are held before they're written to the send
    /// history. An unrecorded send is a contact the app will offer to mail a
    /// second time, so they're written as the run goes — and anything left
    /// unrecorded by a close is written the next time the app opens.
    private static let recordEvery = 5
    /// Gmail's search can take a few seconds to list a mail it has just
    /// accepted. A mail cut off more recently than this is given the time before
    /// its Sent mail is searched, so "not there" means not sent.
    private static let searchSettle: TimeInterval = 20
    /// How long to wait after Gmail's first, second… rate limit in a row before
    /// trying the same mail again, when Gmail didn't say how long. Each step
    /// doubles; a success resets it.
    static let rateLimitBackoff: [Duration] = [.seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(480)]
    /// The longest wait sat out with the run still going. Longer than this —
    /// a daily sending limit, typically — and the batch pauses instead, and
    /// carries on by itself at that time (`resumeAt`).
    static let longestWait: TimeInterval = 15 * 60
    /// When Gmail's limit stops a batch without saying until when, it's tried
    /// again after this long.
    static let limitRetry: TimeInterval = 60 * 60
    /// Finished batches are kept this long, for the queue to show what went.
    private static let keepFinished: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - State

    /// Every batch, oldest first — the order they're sent in.
    private(set) var batches: [MailBatch] = []
    /// The batch mail is going out from right now.
    private(set) var runningBatchID: UUID?
    /// Pause was tapped and the mail already in flight is finishing.
    private(set) var isStopping = false
    /// Set when a run finishes so the shelf can report it. Cleared by `acknowledge()`.
    private(set) var outcome: Outcome?
    /// Advanced whenever a scheduled time may have passed, so what's due is
    /// worked out afresh — `Date.now` on its own isn't something a view can watch.
    private(set) var clock = Date.now
    /// Due batches the user has put off for this session with "Not Now". Still
    /// due, and still in the queue — just not asked about again until reopened.
    private(set) var snoozed: Set<UUID> = []
    /// The queue was asked to be shown — by the shelf, the Live Activity, or
    /// a link. `RootView` switches to Activity and Activity opens its Queued
    /// lane, then clears it.
    var isOpenRequested = false

    /// The run is sitting out a Gmail rate limit: which batch, until when, and
    /// what Gmail said. Nil while sending normally.
    private(set) var cooldown: Cooldown?

    struct Cooldown: Equatable {
        let batchID: UUID
        let until: Date
        let reason: String
        /// How many limits in a row this is.
        let attempt: Int
    }

    // MARK: - Transport

    /// Delivers one mail and reports what the provider called it. Injected so the
    /// queue stays independent of Gmail auth.
    var sender: ((_ to: String, _ subject: String, _ body: String, _ fromName: String) async throws -> Delivery?)?
    /// Looks in Sent mail for a mail to `recipient` handed over since `since`:
    /// the delivery when it's there, nil when it isn't. Throws when it can't tell.
    var verifier: ((_ recipient: String, _ since: Date) async throws -> Delivery?)?
    /// Records delivered mails in the send history and says whether the write
    /// landed. Ones that didn't are offered again next time.
    var onRecord: (([Contact.ID: SentMail]) async -> Bool)?

    private var file: JSONFile<[MailBatch]>?
    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var wakeTask: Task<Void, Never>?
    private var isReconciling = false

    // MARK: - Reading

    var running: MailBatch? { runningBatchID.flatMap(batch) }

    func batch(_ id: UUID) -> MailBatch? { batches.first { $0.id == id } }

    var isRunning: Bool { runningBatchID != nil }

    /// The contacts some batch is still going to mail, so a new batch can leave
    /// them out rather than write to them twice.
    var waitingContactIDs: Set<Contact.ID> {
        Set(batches.flatMap { batch in batch.mails.filter(\.status.isWaiting).map(\.id) })
    }

    /// The next scheduled batch still waiting for its time.
    var nextScheduled: MailBatch? {
        batches.filter { $0.isScheduled(at: clock) }.min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    /// A scheduled batch whose time has come, waiting on the user's go-ahead.
    var readyBatch: MailBatch? {
        batches.first { $0.isDue(at: clock) }
    }

    /// The ready batch to ask about now — not one put off with "Not Now".
    var dueBatch: MailBatch? {
        batches.first { $0.isDue(at: clock) && !snoozed.contains($0.id) }
    }

    /// Batches with mail left that won't go until the user says so.
    var pausedBatches: [MailBatch] { batches.filter { $0.isPaused && $0.hasWork } }

    /// True whenever the shelf has something to show.
    var isActive: Bool { isRunning || outcome != nil || batches.contains(where: \.hasWork) }

    // The running batch's progress, for the shelf.
    var total: Int { running?.mails.count ?? 0 }
    var completed: Int { running.map { $0.sent + $0.failed } ?? 0 }
    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    // MARK: - Loading

    /// Open this account's queue. Anything left mid-send is paused — it goes on
    /// when the user says, not the moment the app happens to open — while a
    /// scheduled batch that hasn't started keeps waiting for its time.
    func load(account: String) {
        guard !isRunning else { return }
        SendLiveActivity.shared.reset()
        let file = JSONFile<[MailBatch]>(name: "mail-queue-\(account).json")
        self.file = file
        var loaded = file.load() ?? []
        loaded.removeAll { $0.isFinished && $0.createdAt < Date.now.addingTimeInterval(-Self.keepFinished) }
        for index in loaded.indices where loaded[index].hasWork && !loaded[index].isPaused {
            let waitingForItsTime = loaded[index].scheduledFor != nil && loaded[index].startedAt == nil
            if !waitingForItsTime {
                loaded[index].isPaused = true
                loaded[index].pauseReason = "The app closed while this was sending. Resume to carry on — anything cut off is checked in Sent mail first."
            }
        }
        batches = loaded
        outcome = nil
        snoozed = []
        save()
        tick()
    }

    /// Settle what the last session left undecided: find out whether each mail
    /// cut off mid-send went out, and write any sends not yet in the history.
    func reconcile() async {
        guard !isReconciling, !isRunning else { return }
        isReconciling = true
        defer { isReconciling = false }

        for batch in batches {
            for mail in batch.mails {
                guard case .sending(let since) = mail.status else { continue }
                // Leave it for the run to check if it can't be checked now.
                // (Not `try?`: that would read "not in Sent" as "couldn't look".)
                let delivery: Delivery?
                do { delivery = try await verify(mail, since: since) } catch { continue }
                // Only if nothing has touched it meanwhile.
                guard self.mail(mail.id, in: batch.id)?.status == mail.status else { continue }
                set(mail.id, in: batch.id, to: delivery)
            }
        }
        save()
        await recordDeliveries()
    }

    // MARK: - Queueing

    /// Add a batch. Sent straight away unless it's scheduled, in which case the
    /// system is left a notification for its time.
    func enqueue(_ batch: MailBatch) {
        guard !batch.mails.isEmpty else { return }
        batches.append(batch)
        save()
        if batch.scheduledFor != nil {
            ScheduledMailNotifier.schedule(batch)
            tick()
        } else {
            startNext()
        }
    }

    /// Stop after the mail in flight. Nothing is lost: the rest wait, paused.
    ///
    /// Never cancels the request already in flight — cancellation reaches into a
    /// Gmail request that may already have been accepted, and a mail aborted
    /// client-side but delivered would be counted as unsent.
    func pause(_ id: UUID) {
        update(id) { batch in
            batch.isPaused = true
            batch.pauseReason = nil
            batch.resumeAt = nil
        }
        ScheduledMailNotifier.cancelResume(id)
        ScheduledMailNotifier.cancel(id)
        if runningBatchID == id { isStopping = true }
        SendLiveActivity.shared.sync(with: self)
    }

    /// Carry on with a paused batch — or, for a scheduled one, go back to waiting
    /// for its time.
    func resume(_ id: UUID) {
        ScheduledMailNotifier.cancelResume(id)
        update(id) { batch in
            batch.isPaused = false
            batch.pauseReason = nil
            batch.resumeAt = nil
            if !batch.isScheduled() { batch.startedAt = batch.startedAt ?? .now }
        }
        if let updated = self.batch(id), updated.isScheduled() {
            ScheduledMailNotifier.schedule(updated)
        }
        snoozed.remove(id)
        startNext()
    }

    /// Send a scheduled or paused batch now.
    func sendNow(_ id: UUID) {
        ScheduledMailNotifier.cancelResume(id)
        update(id) { batch in
            batch.isPaused = false
            batch.pauseReason = nil
            batch.resumeAt = nil
            batch.startedAt = batch.startedAt ?? .now
        }
        ScheduledMailNotifier.cancel(id)
        snoozed.remove(id)
        startNext()
    }

    /// Move a batch that isn't sending to a new time. What's left of it waits
    /// for that time, as if it had never started.
    func reschedule(_ id: UUID, to date: Date) {
        guard runningBatchID != id else { return }
        update(id) { batch in
            batch.scheduledFor = date
            batch.startedAt = nil
            batch.isPaused = false
            batch.pauseReason = nil
            batch.resumeAt = nil
        }
        ScheduledMailNotifier.cancelResume(id)
        snoozed.remove(id)
        if let batch = batch(id) { ScheduledMailNotifier.schedule(batch) }
        tick()
    }

    /// Put the ones that failed back in line and carry on.
    func retryFailed(_ id: UUID) {
        update(id) { batch in
            for index in batch.mails.indices where batch.mails[index].status.isFailed {
                batch.mails[index].status = .pending
            }
        }
        resume(id)
    }

    /// Take a batch out of the queue. Not while it's sending: pause it first.
    func remove(_ id: UUID) {
        guard runningBatchID != id, let batch = batch(id) else { return }
        recordBeforeForgetting([batch])
        ScheduledMailNotifier.cancel(id)
        batches.removeAll { $0.id == id }
        snoozed.remove(id)
        if outcome?.batchID == id { outcome = nil }
        save()
    }

    func clearFinished() {
        recordBeforeForgetting(batches.filter(\.isFinished))
        batches.removeAll(where: \.isFinished)
        if let outcome, batch(outcome.batchID) == nil { self.outcome = nil }
        save()
    }

    /// Mails that can be taken out of the queue without losing anything: not
    /// sent, and not possibly sent (a mail cut off mid-send is checked first).
    func removableCount(in id: UUID) -> Int {
        guard runningBatchID != id else { return 0 }
        return batch(id)?.mails.count { $0.status.isRemovable } ?? 0
    }

    /// Take mails out of a batch — they won't be sent. Sent mail stays as the
    /// record it is; a batch left with nothing in it goes too.
    func removeMails(_ mailIDs: Set<Contact.ID>, from id: UUID) {
        guard runningBatchID != id else { return }
        update(id) { batch in
            batch.mails.removeAll { mailIDs.contains($0.id) && $0.status.isRemovable }
        }
        dropEmptyBatches()
    }

    /// Every failed mail, out of every batch not sending right now.
    func clearFailed() {
        for batch in batches where batch.failed > 0 && runningBatchID != batch.id {
            update(batch.id) { $0.mails.removeAll(where: \.status.isFailed) }
        }
        dropEmptyBatches()
    }

    /// Everything but the batch sending right now. What was sent is written to
    /// the history first; nothing still waiting goes out.
    func clearAll() {
        let leaving = batches.filter { $0.id != runningBatchID }
        recordBeforeForgetting(leaving)
        for batch in leaving { ScheduledMailNotifier.cancel(batch.id) }
        batches.removeAll { $0.id != runningBatchID }
        snoozed = []
        if let outcome, outcome.batchID != runningBatchID { self.outcome = nil }
        save()
        tick()
    }

    private func dropEmptyBatches() {
        let empty = batches.filter { $0.mails.isEmpty }.map(\.id)
        guard !empty.isEmpty else { return }
        for id in empty { ScheduledMailNotifier.cancel(id) }
        batches.removeAll { empty.contains($0.id) }
        if let outcome, empty.contains(outcome.batchID) { self.outcome = nil }
        save()
    }

    /// Mail these batches sent that isn't in the send history yet is written
    /// there before the batches go — the queue is the only place it's known.
    private func recordBeforeForgetting(_ leaving: [MailBatch]) {
        let records = Self.unrecorded(in: leaving).records
        guard !records.isEmpty, let onRecord else { return }
        Task { _ = await onRecord(records) }
    }

    /// "Not Now" on a due batch: stop asking for this session.
    func snooze(_ id: UUID) { snoozed.insert(id) }

    /// Ask about a due batch again — its notification was tapped.
    func unsnooze(_ id: UUID) {
        snoozed.remove(id)
        tick()
    }

    /// Dismiss a finished run's result.
    func acknowledge() { outcome = nil }

    /// Look at the time again: something scheduled may have come due. Called
    /// when the app comes back to the front, and by a timer while it's open.
    func tick() {
        clock = .now
        wakeTask?.cancel()
        // A batch Gmail's limit stopped carries on by itself once it's time.
        for batch in batches where batch.isPaused && batch.hasWork {
            if let at = batch.resumeAt, at <= clock { resume(batch.id) }
        }
        let resumes = batches.compactMap { $0.isPaused ? $0.resumeAt : nil }
        guard let next = ([nextScheduled?.scheduledFor].compactMap { $0 } + resumes).min() else { return }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    // MARK: - Draining

    /// Whether a batch goes when its turn comes, without asking.
    private func isRunnable(_ batch: MailBatch) -> Bool {
        batch.hasWork && !batch.isPaused && (batch.scheduledFor == nil || batch.startedAt != nil)
    }

    /// Start the next batch in line, if nothing is sending.
    private func startNext() {
        guard runningBatchID == nil, let next = batches.first(where: isRunnable) else { return }
        runningBatchID = next.id
        isStopping = false
        outcome = nil
        update(next.id) { $0.startedAt = $0.startedAt ?? .now }
        Task { [weak self] in await self?.drain(next.id) }
    }

    private func drain(_ id: UUID) async {
        beginAssertion()
        defer { endAssertion() }

        var sent = 0
        var failed: [String] = []
        var stoppedBecause: String?
        /// Gmail rate limits in a row, for the backoff.
        var limited = 0
        SendLiveActivity.shared.sync(with: self)

        while let batch = batch(id), !batch.isPaused,
              let mail = batch.mails.first(where: \.status.isWaiting) {
            // Cut off mid-send last time: find out before sending it again.
            if case .sending(let since) = mail.status {
                do {
                    if let delivery = try await verify(mail, since: since) {
                        set(mail.id, in: id, to: delivery)
                        sent += 1
                        continue
                    }
                } catch let error as GmailAuthError where error.endsRun {
                    update(id) { $0.isPaused = true }
                    stoppedBecause = error.localizedDescription
                    break
                } catch is URLError {
                    // Offline: it can be checked later, so wait for that.
                    update(id) { $0.isPaused = true }
                    stoppedBecause = "Couldn't check whether the mail to \(mail.displayName) already went out. Resume when you're online."
                    break
                } catch {
                    // It can't be checked at all. Not sending it again is the
                    // safe way round: a second mail can't be taken back.
                    setStatus(mail.id, in: id, .failed(reason: "Couldn't confirm whether it went out, so it wasn't sent again."))
                    failed.append(mail.displayName)
                    continue
                }
            }

            guard let text = mail.rendered(in: batch) else {
                setStatus(mail.id, in: id, .failed(reason: "Its template is missing."))
                failed.append(mail.displayName)
                continue
            }

            // Saved *before* the request: if the app is closed while it's in
            // flight, the next launch knows to check rather than to resend.
            setStatus(mail.id, in: id, .sending(since: .now))
            do {
                // No transport means nothing was delivered. Recording these as
                // sent would mark a whole batch of contacts as mailed without a
                // single mail leaving the account.
                guard let sender else { throw MailQueueError.noTransport }
                let delivery = try await sender(mail.recipient, text.subject, text.body, batch.fromName)
                setStatus(mail.id, in: id, .sent(at: .now, messageID: delivery?.messageID,
                                                 threadID: delivery?.threadID, recorded: false))
                sent += 1
                limited = 0
            } catch GmailAuthError.rateLimited(let message, let retryAt) {
                // Gmail took nothing: this mail goes back first in line, and
                // the run waits — the time Gmail gave, else a doubling step.
                setStatus(mail.id, in: id, .pending)
                limited += 1
                let step = Self.rateLimitBackoff[min(limited, Self.rateLimitBackoff.count) - 1]
                let until = retryAt ?? .now.addingTimeInterval(TimeInterval(step.components.seconds))
                let wait = until.timeIntervalSinceNow
                if wait > Self.longestWait || limited > Self.rateLimitBackoff.count {
                    // Too long to sit out with the run open: pause, and carry
                    // on by itself then — with a notification, as the app may
                    // well be closed by that time.
                    let resumeAt = retryAt ?? .now.addingTimeInterval(Self.limitRetry)
                    update(id) {
                        $0.isPaused = true
                        $0.resumeAt = resumeAt
                    }
                    if let batch = self.batch(id) { ScheduledMailNotifier.scheduleResume(batch, at: resumeAt) }
                    stoppedBecause = "Gmail's sending limit was reached (\(message)). Sending carries on by itself at "
                        + resumeAt.formatted(date: Calendar.current.isDateInToday(resumeAt) ? .omitted : .abbreviated,
                                             time: .shortened) + "."
                    tick()
                    break
                }
                cooldown = Cooldown(batchID: id, until: until, reason: message, attempt: limited)
                SendLiveActivity.shared.sync(with: self)
                let waited = await waitOut(until, batch: id)
                cooldown = nil
                SendLiveActivity.shared.sync(with: self)
                if !waited { break }
                continue
            } catch let error as GmailAuthError where error.endsRun {
                // Every mail after this one would fail the same way. Stop, and
                // leave the rest — this one included — waiting to be resumed.
                setStatus(mail.id, in: id, .pending)
                update(id) { $0.isPaused = true }
                stoppedBecause = error.localizedDescription
                break
            } catch is URLError {
                // The connection went mid-request, so Gmail may have the mail
                // or may not. It stays `sending` — checked in Sent mail before
                // anything else happens to it — and the batch waits.
                update(id) { $0.isPaused = true }
                stoppedBecause = "Lost the connection sending to \(mail.displayName). Resume to check whether it went out and carry on."
                break
            } catch {
                setStatus(mail.id, in: id, .failed(reason: Self.reason(for: error)))
                failed.append(mail.displayName)
            }

            if unrecordedCount >= Self.recordEvery { await recordDeliveries() }
            if let batch = self.batch(id), !batch.isPaused, batch.hasWork {
                try? await Task.sleep(for: Self.spacing + .milliseconds(Int.random(in: -Self.jitter...Self.jitter)))
            }
        }

        // The batch says why it stopped for as long as it's paused, not only
        // on the shelf until that's dismissed.
        if let stoppedBecause { update(id) { $0.pauseReason = stoppedBecause } }

        // Record even a stopped run's successes — those mails really were sent,
        // and losing them would offer to re-send people who've already been mailed.
        await recordDeliveries()

        let paused = batch(id).map { $0.isPaused && $0.hasWork } ?? false
        runningBatchID = nil
        isStopping = false
        cooldown = nil
        outcome = Outcome(batchID: id, sent: sent, failed: failed,
                          stoppedBecause: stoppedBecause, isPaused: paused)
        startNext()
        SendLiveActivity.shared.sync(with: self)
    }

    /// Sit out a rate limit until `until`, a second at a time so Pause still
    /// stops it. False when the batch was paused (or removed) meanwhile.
    private func waitOut(_ until: Date, batch id: UUID) async -> Bool {
        while until.timeIntervalSinceNow > 0 {
            guard let batch = batch(id), !batch.isPaused else { return false }
            try? await Task.sleep(for: .seconds(min(1, until.timeIntervalSinceNow)))
        }
        return batch(id).map { !$0.isPaused } ?? false
    }

    /// A send failure as one short line: Gmail's refusals arrive as whole JSON
    /// documents.
    private static func reason(for error: Error) -> String {
        let text = error.localizedDescription
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 140 ? String(firstLine.prefix(140)) + "…" : firstLine
    }

    // MARK: - Checking and recording

    /// Whether a mail cut off mid-send is in Sent mail. Waits out Gmail's search
    /// delay first, so a mail accepted a moment ago isn't missed.
    private func verify(_ mail: QueuedMail, since: Date) async throws -> Delivery? {
        guard let verifier else { throw MailQueueError.noTransport }
        let settle = Self.searchSettle - Date.now.timeIntervalSince(since)
        if settle > 0 { try await Task.sleep(for: .seconds(settle)) }
        return try await verifier(mail.recipient, since)
    }

    /// Mark a mail found in Sent as delivered, or put it back in line.
    private func set(_ mailID: Contact.ID, in batchID: UUID, to delivery: Delivery?) {
        if let delivery {
            setStatus(mailID, in: batchID, .sent(at: .now, messageID: delivery.messageID,
                                                 threadID: delivery.threadID, recorded: false))
        } else {
            setStatus(mailID, in: batchID, .pending)
        }
    }

    private var unrecordedCount: Int {
        batches.reduce(0) { total, batch in
            total + batch.mails.count { if case .sent(_, _, _, false) = $0.status { true } else { false } }
        }
    }

    /// Write every delivered mail not yet in the send history. Each is written
    /// again from its batch — the same text that went out — rather than held.
    private func recordDeliveries() async {
        guard let onRecord else { return }
        let (records, written) = Self.unrecorded(in: batches)
        guard !records.isEmpty, await onRecord(records) else { return }
        for (batchID, mailID) in written {
            guard case .sent(let at, let messageID, let threadID, false)? = mail(mailID, in: batchID)?.status else { continue }
            setStatus(mailID, in: batchID, .sent(at: at, messageID: messageID, threadID: threadID, recorded: true))
        }
    }

    /// Delivered mail not yet in the send history, written out as it went.
    private static func unrecorded(in batches: [MailBatch])
        -> (records: [Contact.ID: SentMail], written: [(batch: UUID, mail: Contact.ID)]) {
        var records: [Contact.ID: SentMail] = [:]
        var written: [(batch: UUID, mail: Contact.ID)] = []
        for batch in batches {
            for mail in batch.mails {
                guard case .sent(_, let messageID, let threadID, false) = mail.status,
                      let text = mail.rendered(in: batch) else { continue }
                records[mail.id] = SentMail(subject: text.subject, body: text.body,
                                            gmailMessageID: messageID, gmailThreadID: threadID)
                written.append((batch.id, mail.id))
            }
        }
        return (records, written)
    }

    // MARK: - Editing

    private func mail(_ mailID: Contact.ID, in batchID: UUID) -> QueuedMail? {
        batch(batchID)?.mails.first { $0.id == mailID }
    }

    private func setStatus(_ mailID: Contact.ID, in batchID: UUID, _ status: QueuedMail.Status) {
        update(batchID) { batch in
            guard let index = batch.mails.firstIndex(where: { $0.id == mailID }) else { return }
            batch.mails[index].status = status
        }
        SendLiveActivity.shared.sync(with: self)
    }

    /// Change one batch and save. Looked up by id each time: the list can change
    /// under a run while it waits on the network.
    private func update(_ id: UUID, _ change: (inout MailBatch) -> Void) {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        change(&batches[index])
        save()
    }

    private func save() {
        file?.save(batches)
    }

    // MARK: - Background execution

    /// Ask for a few extra seconds if the app is backgrounded mid-run. This isn't
    /// a guarantee of finishing: once iOS suspends the app the loop stops
    /// awaiting and picks up again on return — and if iOS ends the app instead,
    /// the batch is on disk, and comes back paused.
    ///
    /// The time running out has to be answered by handing the assertion back.
    /// An app that holds one past its expiry isn't suspended, it's terminated.
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
