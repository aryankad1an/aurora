import Foundation
import Observation

/// Finds out which mails were answered, by reading the mailbox they were
/// sent from.
///
/// The signal is Gmail's own thread id, not a match on sender and time. Every
/// reply lands in the thread of the message it answers, whoever sends it — so a
/// contact answering from their personal address, or a colleague picking up a
/// mail sent to `recruiting@`, is still detected. Matching inbound mail by
/// address would miss both, and would count a newsletter from the same address
/// as a reply.
///
/// Two passes, in order:
///
/// 1. **Recover.** Sends recorded before the app captured thread ids have none.
///    Their messages are still in Sent, and we know exactly who each one went to
///    and when, so a one-off search recovers the thread id — this is a lookup,
///    not a guess. It runs once per send and never again.
/// 2. **Check.** For every send that has a thread and no reply yet, read the
///    thread's headers and look for a message that isn't ours.
///
/// Like `MailQueue`, this holds no reference to the auth or data stores: it is
/// handed a `reader` closure by `RootView`, so the refresh token never leaves
/// `GmailAuthStore`.
@Observable
@MainActor
final class ReplySync {

    /// What one sync did. `failed` counts requests that errored but didn't stop
    /// the run — a single unreadable thread shouldn't abandon the other hundred.
    struct Outcome {
        var recovered = 0
        var replies = 0
        var bounced = 0
        var failed = 0
        /// Requests that came back with an answer, whatever the answer was.
        var read = 0

        var changedAnything: Bool { recovered > 0 || replies > 0 }
        /// Everything that was asked failed: nothing was checked at all.
        var readNothing: Bool { failed > 0 && read == 0 }
    }

    /// Progress, for the UI. `total` is 0 while idle.
    struct Progress {
        var label = ""
        var done = 0
        var total = 0

        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    private(set) var isSyncing = false
    private(set) var progress = Progress()
    private(set) var lastSyncedAt: Date?
    private(set) var lastOutcome: Outcome?

    /// Set when Gmail refuses the read for want of the `gmail.readonly` scope —
    /// i.e. the stored token predates reply tracking. The UI turns this into a
    /// "reconnect Gmail" prompt rather than an error alert, because that's the
    /// only thing that fixes it.
    private(set) var needsReconnect = false

    /// For failures found outside a sync — a send refused because the Gmail
    /// session has ended — so Profile offers the reconnect either way.
    func noteReconnectNeeded() {
        needsReconnect = true
    }

    /// Set when the database is missing the reply-tracking columns — the app is
    /// newer than the schema, and the fix is the migration in the README.
    private(set) var needsMigration = false
    var errorMessage: String?

    /// Contact ids whose thread came back with a delivery failure. Recomputed
    /// every sync from the thread itself (never stored), so it can't go stale —
    /// Quick Actions offers these up to be marked invalid.
    private(set) var bouncedContactIDs: Set<String> = []

    /// Send ids where a Sent message search was attempted but returned nothing.
    /// Kept in memory so subsequent syncs don't re-query Gmail Sent repeatedly
    /// for orphan sends that cannot be recovered.
    private var unrecoverableSendIDs: Set<String> = []

    /// Performs an authorized Gmail GET. Injected so this type stays independent
    /// of how the account is authenticated.
    var reader: ((String, [URLQueryItem]) async throws -> Data)?

    /// How far back to keep checking unanswered sends. A mail that has been
    /// silent for four months isn't about to be answered, and re-reading those
    /// threads on every sync costs a request each, forever.
    nonisolated private static let checkWindow: TimeInterval = 120 * 24 * 60 * 60
    nonisolated private static let recoveryWindow: TimeInterval = 10 * 60
    nonisolated private static let driftWindow: TimeInterval = 24 * 60 * 60
    /// How recently a sync must have run for the next one to read only threads
    /// with new inbound mail instead of every open thread.
    nonisolated private static let deltaWindow: TimeInterval = 7 * 24 * 60 * 60
    nonisolated private static let concurrency = 5

    // MARK: - Running

    /// Recover missing thread ids, then look for replies. Safe to call often:
    /// each send is recovered once and checked only while it's unanswered.
    ///
    /// - Parameters:
    ///   - sends: user's sent records.
    ///   - emailByContact: recipient address per contact id, needed to search Sent.
    ///   - excludingContactIDs: contacts already known to be invalid/bounced, to skip checking.
    @discardableResult
    func run(sends: [MailSend],
             emailByContact: [String: String],
             excludingContactIDs: Set<String> = [],
             forceFullCheck: Bool = false) async -> Outcome {
        guard !isSyncing, reader != nil else { return Outcome() }
        isSyncing = true
        errorMessage = nil
        needsReconnect = false
        needsMigration = SupabaseAPI.replyColumnsMissing
        var outcome = Outcome()
        var completed = false
        defer {
            isSyncing = false
            progress = Progress()
            // Only stamp a completed run. A cancelled one has checked nothing, and
            // "Checked just now" would be a lie that also hides the real state.
            if completed {
                lastSyncedAt = .now
                lastOutcome = outcome
            }
        }

        var sends = sends
        do {
            let recovered = try await recoverThreadIDs(in: sends, emailByContact: emailByContact)
            outcome.recovered = recovered.count
            outcome.failed += recovered.failed
            outcome.read += recovered.read
            // Fold the recovered ids back in so this run can check them straight
            // away, instead of finding a reply only on the next sync.
            sends = sends.map { send in
                guard let message = recovered.threadIDs[send.id] else { return send }
                return send.attaching(message: message)
            }

            let checked = try await checkForReplies(in: sends,
                                                    excludingContactIDs: excludingContactIDs,
                                                    alwaysChecking: Set(recovered.threadIDs.keys),
                                                    forceFullCheck: forceFullCheck)
            outcome.replies = checked.replies
            outcome.bounced = checked.bounced
            outcome.failed += checked.failed
            outcome.read += checked.read
            // A delta sync only reads threads with new mail, so a bounce found
            // earlier is still a bounce: keep it unless the thread was re-read.
            // Contacts since marked invalid are dealt with and drop out.
            if checked.wasFullCheck {
                bouncedContactIDs = checked.bouncedContacts
            } else {
                bouncedContactIDs.subtract(checked.checkedContacts)
                bouncedContactIDs.formUnion(checked.bouncedContacts)
            }
            bouncedContactIDs.subtract(excludingContactIDs)
            // A run where every request failed (offline, Gmail down) read
            // nothing, and stamping it "Checked just now" would say the silence
            // on screen is current when it's just as stale as before.
            if outcome.readNothing {
                errorMessage = "Couldn't reach Gmail, so nothing was checked. Try again in a moment."
            } else {
                completed = true
            }
        } catch let error as GmailAuthError where error.needsReconnect {
            needsReconnect = true
        } catch let error as SupabaseError where error.isSchemaOutOfDate {
            needsMigration = true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
        return outcome
    }

    // MARK: - Pass 1: recover thread ids for older sends

    private struct Recovered {
        var threadIDs: [String: GmailAuthStore.SentMessage] = [:]
        var failed = 0
        var read = 0
        var count: Int { threadIDs.count }
    }

    private enum RecoverResult {
        case attached(sendID: String, message: GmailAuthStore.SentMessage)
        case notFound(sendID: String)
        case skipped
        case failed
    }

    private func recoverThreadIDs(in sends: [MailSend],
                                  emailByContact: [String: String]) async throws -> Recovered {
        guard let reader else { throw GmailAuthError.notConnected }
        let targets = sends.filter {
            $0.gmailThreadID == nil && $0.sentAt != nil && !unrecoverableSendIDs.contains($0.id)
        }
        guard !targets.isEmpty else { return Recovered() }

        progress = Progress(label: "Matching sent mail", done: 0, total: targets.count)
        var result = Recovered()

        for chunk in stride(from: 0, to: targets.count, by: Self.concurrency).map({
            Array(targets[$0..<min($0 + Self.concurrency, targets.count)])
        }) {
            try Task.checkCancellation()
            let chunkResults = try await withThrowingTaskGroup(of: RecoverResult.self) { group in
                for send in chunk {
                    group.addTask {
                        guard let sentAt = send.sentAt,
                              let recipient = emailByContact[send.contactID],
                              Self.isSearchable(recipient) else {
                            return .skipped
                        }
                        do {
                            guard let message = try await Self.findSentMessage(to: recipient, around: sentAt, reader: reader) else {
                                return .notFound(sendID: send.id)
                            }
                            return .attached(sendID: send.id, message: message)
                        } catch let error as GmailAuthError where error.endsRun {
                            throw error
                        } catch let error as SupabaseError where error.isSchemaOutOfDate {
                            throw error
                        } catch {
                            return .failed
                        }
                    }
                }
                var outcomes: [RecoverResult] = []
                for try await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }

            for outcome in chunkResults {
                switch outcome {
                case .attached(let sendID, let message):
                    result.read += 1
                    do {
                        try await SupabaseAPI.attachThread(sendID: sendID,
                                                           messageID: message.id,
                                                           threadID: message.threadID)
                        result.threadIDs[sendID] = message
                    } catch {
                        result.failed += 1
                    }
                case .notFound(let sendID):
                    result.read += 1
                    unrecoverableSendIDs.insert(sendID)
                case .skipped:
                    break
                case .failed:
                    result.failed += 1
                }
            }
            progress.done += chunk.count
        }
        return result
    }

    /// Whether a value is safe to interpolate into an API path: letters and
    /// digits only, which is what Gmail's message and thread ids are.
    nonisolated static func isSafePathComponent(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy(\.isHexDigit)
    }

    /// Whether an address is safe to drop into a Gmail search expression. A
    /// stored address with a space or a quote in it would change the shape of the
    /// query rather than the value being searched for, so those rows are skipped
    /// instead: no thread id is worse than the wrong thread id.
    nonisolated static func isSearchable(_ email: String) -> Bool {
        guard !email.isEmpty,
              let atIndex = email.firstIndex(of: "@"),
              atIndex != email.startIndex,
              email.index(after: atIndex) != email.endIndex else {
            return false
        }
        return email.allSatisfy { !$0.isWhitespace && $0 != "\"" && $0 != "(" && $0 != ")" }
    }

    /// The Sent copy of one mail: an exact `to:` plus a tight time window, which
    /// resolves to a single message. `messages.list` returns the thread id in the
    /// listing itself, so this needs no follow-up fetch.
    ///
    /// If the tight window finds nothing (the recorded time drifted from Gmail's),
    /// a day either side is tried — but that answer is only taken when it's the
    /// *only* mail to that person in the window. With two candidates there's no
    /// telling which one this send was, and attaching the wrong thread would
    /// credit a reply to the wrong mail. No thread id beats the wrong one.
    nonisolated private static func findSentMessage(to recipient: String,
                                                    around date: Date,
                                                    reader: (String, [URLQueryItem]) async throws -> Data) async throws -> GmailAuthStore.SentMessage? {
        struct Listing: Decodable { let messages: [GmailAuthStore.SentMessage]? }
        func search(within window: TimeInterval) async throws -> [GmailAuthStore.SentMessage] {
            let after = Int(date.addingTimeInterval(-window).timeIntervalSince1970)
            let before = Int(date.addingTimeInterval(window).timeIntervalSince1970)
            let data = try await reader("messages", [
                URLQueryItem(name: "q", value: "in:sent to:\(recipient) after:\(after) before:\(before)"),
                URLQueryItem(name: "maxResults", value: "2")
            ])
            return try JSONDecoder().decode(Listing.self, from: data).messages ?? []
        }

        if let exact = try await search(within: recoveryWindow).first { return exact }
        let nearby = try await search(within: driftWindow)
        return nearby.count == 1 ? nearby[0] : nil
    }

    // MARK: - Pass 2: look for an answer in each thread

    private struct Checked {
        var replies = 0
        var bounced = 0
        var failed = 0
        var read = 0
        var bouncedContacts: Set<String> = []
        /// Contacts whose threads were actually read this run.
        var checkedContacts: Set<String> = []
        var wasFullCheck = true
    }

    private enum CheckResult {
        case reply(sendID: String, at: Date, from: String, snippet: String?)
        case bounce(contactID: String)
        case silent
        case failed
    }

    /// Threads that received mail from someone else since `date`, so a delta
    /// sync reads only those. Nil when the answer doesn't fit in one page — then
    /// the caller can't tell what it's missing and has to read everything.
    nonisolated private static func findIncomingThreadIDs(after date: Date,
                                                          reader: (String, [URLQueryItem]) async throws -> Data) async throws -> Set<String>? {
        let data = try await reader("messages", [
            URLQueryItem(name: "q", value: "after:\(Int(date.timeIntervalSince1970)) -from:me"),
            URLQueryItem(name: "maxResults", value: "500")
        ])
        struct Listing: Decodable {
            let messages: [GmailAuthStore.SentMessage]?
            let nextPageToken: String?
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        guard listing.nextPageToken == nil else { return nil }
        return Set(listing.messages?.map(\.threadID) ?? [])
    }

    /// - Parameter alwaysChecking: sends to read even on a delta sync — ones whose
    ///   thread was only just recovered, and so has never been read at all.
    private func checkForReplies(in sends: [MailSend],
                                 excludingContactIDs: Set<String>,
                                 alwaysChecking: Set<String>,
                                 forceFullCheck: Bool) async throws -> Checked {
        guard let reader else { throw GmailAuthError.notConnected }
        let cutoff = Date().addingTimeInterval(-Self.checkWindow)
        let activeSends = sends.filter {
            $0.gmailThreadID != nil &&
            !$0.hasReplied &&
            !excludingContactIDs.contains($0.contactID) &&
            ($0.sentAt ?? .distantPast) > cutoff
        }
        guard !activeSends.isEmpty else { return Checked() }

        // Delta check: after a recent sync, and unless the user asked for a full
        // check, read only threads that have had inbound mail since — with a
        // quarter-hour overlap so nothing falls between two syncs. If that lookup
        // fails or overflows, fall back to reading every open thread.
        var result = Checked()
        let targets: [MailSend]
        if !forceFullCheck,
           let lastSync = lastSyncedAt,
           Date().timeIntervalSince(lastSync) < Self.deltaWindow,
           let incoming = try? await Self.findIncomingThreadIDs(after: lastSync.addingTimeInterval(-15 * 60),
                                                                reader: reader) {
            result.wasFullCheck = false
            targets = activeSends.filter { send in
                alwaysChecking.contains(send.id) || send.gmailThreadID.map(incoming.contains) == true
            }
        } else {
            targets = activeSends
        }
        result.checkedContacts = Set(targets.map(\.contactID))
        guard !targets.isEmpty else { return result }

        progress = Progress(label: "Checking for replies", done: 0, total: targets.count)

        for chunk in stride(from: 0, to: targets.count, by: Self.concurrency).map({
            Array(targets[$0..<min($0 + Self.concurrency, targets.count)])
        }) {
            try Task.checkCancellation()
            let chunkResults = try await withThrowingTaskGroup(of: CheckResult.self) { group in
                for send in chunk {
                    group.addTask {
                        guard let threadID = send.gmailThreadID else { return .silent }
                        do {
                            switch try await Self.firstResponse(inThread: threadID, after: send.sentAt, reader: reader) {
                            case .reply(let date, let sender, let snippet):
                                return .reply(sendID: send.id, at: date, from: sender, snippet: snippet)
                            case .bounce:
                                return .bounce(contactID: send.contactID)
                            case .silent:
                                return .silent
                            }
                        } catch let error as GmailAuthError where error.endsRun {
                            throw error
                        } catch let error as SupabaseError where error.isSchemaOutOfDate {
                            throw error
                        } catch {
                            return .failed
                        }
                    }
                }
                var outcomes: [CheckResult] = []
                for try await outcome in group {
                    outcomes.append(outcome)
                }
                return outcomes
            }

            for outcome in chunkResults {
                switch outcome {
                case .reply(let sendID, let date, let sender, let snippet):
                    result.read += 1
                    do {
                        try await SupabaseAPI.recordReply(sendID: sendID, at: date,
                                                          from: sender, snippet: snippet)
                        result.replies += 1
                    } catch {
                        result.failed += 1
                    }
                case .bounce(let contactID):
                    result.read += 1
                    result.bounced += 1
                    result.bouncedContacts.insert(contactID)
                case .silent:
                    result.read += 1
                case .failed:
                    result.failed += 1
                }
            }
            progress.done += chunk.count
        }
        return result
    }

    private enum ThreadResponse {
        case reply(at: Date, from: String, snippet: String?)
        /// The only thing that came back was a delivery failure.
        case bounce
        case silent
    }

    /// Read one thread's headers and decide whether anybody answered.
    ///
    /// Three things in a thread are *not* an answer, and each is excluded on a
    /// different signal: our own messages (Gmail's `SENT` label), auto-replies
    /// (the `Auto-Submitted` / `Precedence` headers an out-of-office sets), and
    /// bounces (the mailer-daemon sender). Without those filters a fortnight
    /// away from the desk would read as a mailbox full of interested contacts.
    nonisolated private static func firstResponse(inThread threadID: String,
                                                  after sentAt: Date?,
                                                  reader: (String, [URLQueryItem]) async throws -> Data) async throws -> ThreadResponse {
        // The id is interpolated into the request *path*, and `mail_sends` is
        // writable by anyone holding the app's anon key — so it is not
        // necessarily a value this app wrote. A `..` or a `?` in it would aim the
        // request at a different Gmail endpoint entirely. Gmail's ids are hex, so
        // anything else is rejected rather than sent.
        guard isSafePathComponent(threadID) else { return .silent }

        let data = try await reader("threads/\(threadID)", [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "fields", value: "messages(id,labelIds,snippet,internalDate,payload/headers)"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Date"),
            URLQueryItem(name: "metadataHeaders", value: "Auto-Submitted"),
            URLQueryItem(name: "metadataHeaders", value: "Precedence")
        ])
        let thread = try JSONDecoder().decode(GmailThread.self, from: data)

        // Fast-path: if the thread only has our own single send, nobody answered.
        if thread.messages.count <= 1 && (thread.messages.first?.isOurs ?? false) {
            return .silent
        }

        var sawBounce = false
        // Oldest first, so the first qualifying message is the first reply.
        for message in thread.messages.sorted(by: { $0.date < $1.date }) {
            guard !message.isOurs else { continue }
            if let sentAt, message.date < sentAt.addingTimeInterval(-30) { continue }
            if message.isBounce { sawBounce = true; continue }
            if message.isAutomated { continue }
            guard let from = message.from, !from.isEmpty else { continue }
            return .reply(at: message.date,
                          from: from,
                          snippet: message.snippet?.htmlUnescaped)
        }
        return sawBounce ? .bounce : .silent
    }

}

// MARK: - Gmail thread shapes

/// The slice of Gmail's thread resource this needs. Everything is optional:
/// these are other people's messages, and a header that "always" exists won't.
nonisolated private struct GmailThread: Decodable {
    let messages: [Message]

    struct Message: Decodable {
        let id: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Payload?

        struct Payload: Decodable {
            let headers: [Header]?
            struct Header: Decodable { let name: String; let value: String }
        }

        /// Gmail stamps `internalDate` in milliseconds since the epoch. It's the
        /// server's own receive time, so unlike the `Date:` header it can't be
        /// backdated by the sender.
        var date: Date {
            guard let ms = internalDate.flatMap(Double.init) else { return .distantPast }
            return Date(timeIntervalSince1970: ms / 1000)
        }

        /// Our own copy of the mail (or a draft of one), never a response.
        var isOurs: Bool {
            let labels = labelIds ?? []
            return labels.contains("SENT") || labels.contains("DRAFT")
        }

        var from: String? { header("From") }

        /// Out-of-office and other machine-generated replies announce themselves
        /// in the headers; `vacation` is what Gmail's own responder sets.
        var isAutomated: Bool {
            if let auto = header("Auto-Submitted")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), auto != "no" { return true }
            if let precedence = header("Precedence")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ["bulk", "auto_reply", "junk", "list"].contains(precedence) { return true }
            let sender = from ?? ""
            return sender.localizedCaseInsensitiveContains("no-reply")
                || sender.localizedCaseInsensitiveContains("noreply")
                || sender.localizedCaseInsensitiveContains("do-not-reply")
                || sender.localizedCaseInsensitiveContains("donotreply")
        }

        /// A delivery failure — the address is dead, which is the opposite of a
        /// reply and a strong hint the contact should be marked invalid.
        var isBounce: Bool {
            let sender = (from ?? "").lowercased()
            return sender.contains("mailer-daemon") || sender.contains("postmaster")
        }

        private func header(_ name: String) -> String? {
            payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }
}

private extension SupabaseError {
    var isSchemaOutOfDate: Bool {
        if case .schemaOutOfDate = self { return true }
        return false
    }
}
