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

        /// Replies recorded before "no longer in service" answers were known
        /// for what they are, taken back and turned into bounces.
        var corrected = 0

        /// Contacts a name was found for in the account's mail.
        var namesFound = 0

        var changedAnything: Bool { recovered > 0 || replies > 0 || corrected > 0 }
        /// Everything that was asked failed: nothing was checked at all.
        var readNothing: Bool { failed > 0 && read == 0 }
    }

    /// Progress, for the UI. `total` is 0 while idle, and while a step is
    /// still finding out how much it has to do.
    struct Progress {
        var label = ""
        var done = 0
        var total = 0
        /// Which step of the run this is, counting from 1, and how many there are.
        var step = 0
        var steps = 0
        /// What `done` and `total` count: "mails", "notices", "addresses".
        var unit = ""

        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

        /// How far through the whole run: each step an equal share.
        var overall: Double {
            guard steps > 0, step > 0 else { return 0 }
            return min(1, (Double(step - 1) + fraction) / Double(steps))
        }

        /// Everything there is to say about where the run is, in full:
        /// "Step 2 of 6 · Checking for replies · 12 of 80 mails (15%)".
        var summary: String {
            var parts: [String] = []
            if steps > 0 { parts.append("Step \(step) of \(steps)") }
            if !label.isEmpty { parts.append(label) }
            if total > 0 {
                let unitText = unit.isEmpty ? "" : " \(unit)"
                parts.append("\(min(done, total)) of \(total)\(unitText) (\(Int((fraction * 100).rounded()))%)")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// A check's steps, in order. The last runs only when someone mailed has
    /// no name to look up.
    ///
    /// The two bounce steps find different notices: the first reads the ones
    /// that arrived *inside* a sent mail's thread (spotted while checking it for
    /// replies); the second searches the whole inbox, Spam and Trash included,
    /// for the ones that never joined the thread, as many servers send them.
    nonisolated static let stepTitles = [
        "Linking sent mail to threads",
        "Checking threads for replies",
        "Reading bounces found in threads",
        "Searching inbox for other bounces",
        "Searching for “no longer here” replies",
        "Finding names in your mail"
    ]

    /// Start step `step` of this run, before it knows how much it has to do.
    private func beginStep(_ step: Int) {
        progress = Progress(label: Self.stepTitles[step - 1], step: step, steps: progress.steps)
    }

    /// The current step has `total` things to read.
    private func count(_ total: Int, _ unit: String) {
        progress.done = 0
        progress.total = total
        progress.unit = unit
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

    /// Mails that came back undelivered, by contact: from a failure notice in
    /// the mail's own thread, or one found in the inbox (see `scanInbox`).
    /// Saved per account, so a bounce found once stays found until it's dealt
    /// with — marked invalid, or dismissed as not a bounce.
    private(set) var bounces: [Contact.ID: Bounce] = [:]
    /// Failure notices already read from the inbox, so each is fetched once.
    private var seenBounceMessages: Set<String> = []
    /// When each dismissed bounce was dismissed: only a notice that arrives
    /// after that brings the contact back.
    private var dismissedBounces: [Contact.ID: Date] = [:]
    private var bounceFile: JSONFile<BounceLog>?
    /// Up to when this account's mail has been read: the next check reads only
    /// what has come since (see `ReplyCheckpoint`). Saved per account.
    private(set) var checkpoint = ReplyCheckpoint()
    private var checkpointFile: JSONFile<ReplyCheckpoint>?
    /// What each check did, for Activity's timeline. Saved per account.
    private(set) var checkLog = ReplyCheckLog()
    private var checkLogFile: JSONFile<ReplyCheckLog>?
    /// Threads deleted in Gmail, so they aren't asked for again this session.
    private var goneThreadIDs: Set<String> = []

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
    nonisolated private static let concurrency = 5

    // MARK: - Bounces

    /// Open this account's bounce log.
    func loadBounces(account: String) {
        let file = JSONFile<BounceLog>(name: "bounces-\(account).json")
        bounceFile = file
        let log = file.load() ?? BounceLog()
        bounces = Dictionary(log.bounces.map { ($0.contactID, $0) }, uniquingKeysWith: { $0.at > $1.at ? $0 : $1 })
        seenBounceMessages = Set(log.seenMessageIDs)
        dismissedBounces = log.dismissed
        let checkpointFile = JSONFile<ReplyCheckpoint>(name: "reply-checkpoint-\(account).json")
        self.checkpointFile = checkpointFile
        checkpoint = checkpointFile.load() ?? ReplyCheckpoint()
        lastSyncedAt = checkpoint.checkedThrough
        let checkLogFile = JSONFile<ReplyCheckLog>(name: "reply-checks-\(account).json")
        self.checkLogFile = checkLogFile
        checkLog = checkLogFile.load() ?? ReplyCheckLog()
        // A check the app was closed in the middle of never finished.
        for record in checkLog.records where record.result == .running {
            checkLog.update(record.id) {
                $0.result = .stopped("The app closed during this check.")
            }
        }
    }

    /// "Not a bounce": stop flagging this contact until a newer notice arrives.
    func dismissBounce(_ contactID: Contact.ID) {
        dismissedBounces[contactID] = .now
        bounces[contactID] = nil
        saveBounces()
    }

    /// The contacts were marked invalid: their bounces are dealt with. Not a
    /// dismissal — if one is marked valid again and bounces again, it's back.
    func resolveBounces(_ contactIDs: [Contact.ID]) {
        for id in contactIDs { bounces[id] = nil }
        saveBounces()
    }

    /// Keep a bounce unless it was dismissed after it arrived, or an older one
    /// than what's already on file. Says whether it's new.
    @discardableResult
    private func record(_ bounce: Bounce) -> Bool {
        if let dismissed = dismissedBounces[bounce.contactID], bounce.at <= dismissed { return false }
        if let existing = bounces[bounce.contactID] {
            // The same notice read again with its report — after a first read
            // that failed — fills in the status; anything older is ignored.
            let fillsIn = existing.at == bounce.at && existing.status == nil && bounce.status != nil
            guard existing.at < bounce.at || fillsIn else { return false }
        }
        let isNew = bounces[bounce.contactID] == nil
        bounces[bounce.contactID] = bounce
        return isNew
    }

    private func saveBounces() {
        // The newest few thousand notices are plenty to never re-read one.
        let seen = Array(seenBounceMessages.suffix(3000))
        bounceFile?.save(BounceLog(bounces: Array(bounces.values), seenMessageIDs: seen, dismissed: dismissedBounces))
    }

    // MARK: - Running

    /// Recover missing thread ids, then look for replies. Safe to call often:
    /// each send is recovered once and checked only while it's unanswered.
    ///
    /// - Parameters:
    ///   - sends: user's sent records.
    ///   - emailByContact: recipient address per contact id, needed to search Sent.
    ///   - excludingContactIDs: contacts already known to be invalid/bounced, to skip checking.
    ///   - lookingUpNames: addresses to look for a name for in the account's
    ///     mail (`MailboxNames`), as the run's last step.
    @discardableResult
    func run(sends: [MailSend],
             emailByContact: [String: String],
             excludingContactIDs: Set<String> = [],
             forceFullCheck: Bool = false,
             lookingUpNames names: [String] = []) async -> Outcome {
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
        let startedAt = Date.now
        // Mail before this has been read already, unless asked to read it all.
        let since = checkpoint.readFrom(fullCheck: forceFullCheck)
        let noticesSince = checkpoint.noticesReadFrom(fullCheck: forceFullCheck)
        let lookups = MailboxNames.shared.pending(names)
        progress = Progress(steps: lookups.isEmpty ? 5 : 6)
        var record = ReplyCheckRecord(startedAt: startedAt, readFrom: since)
        record.plan = Array(Self.stepTitles.prefix(progress.steps))
        checkLog.begin(record)
        saveCheckLog()
        defer {
            // The latest check replaces the one before it.
            checkLog.keepOnly(record.id)
            checkLog.update(record.id) { entry in
                entry.finishedAt = .now
                if entry.result == .running {
                    if needsReconnect {
                        entry.result = .stopped("Gmail needs reconnecting in Settings.")
                    } else if needsMigration {
                        entry.result = .stopped("The database is missing the reply columns.")
                    } else if let errorMessage {
                        entry.result = .stopped(errorMessage)
                    } else {
                        entry.result = .stopped("Cancelled.")
                    }
                }
            }
            saveCheckLog()
        }
        let after = since.map { " since " + Self.when($0) } ?? " in the last 120 days"
        let noticesAfter = noticesSince.map { " since " + Self.when($0) } ?? ""
        do {
            // Replies that were really "this address is no longer in service".
            let corrected = await correctMisreadReplies(in: sends, emailByContact: emailByContact)
            outcome.corrected = corrected.count
            sends = sends.map { send in
                guard corrected.contains(send.id) else { return send }
                var cleared = send
                cleared.repliedAt = nil
                cleared.replyFrom = nil
                cleared.replySnippet = nil
                return cleared
            }

            beginStep(1)
            let recovered = try await recoverThreadIDs(in: sends, emailByContact: emailByContact)
            outcome.recovered = recovered.count
            outcome.failed += recovered.failed
            outcome.read += recovered.read
            note(record.id, Self.stepTitles[0],
                 recovered.targets == 0
                    ? "Every sent mail already linked to its thread"
                    : "Linked \(recovered.count) of \(recovered.targets) sent mails to their threads"
                        + (recovered.notFound > 0 ? " · \(recovered.notFound) not in Sent" : ""),
                 issues: ReplyCheckLog.issues(recovered.reasons))
            // Fold the recovered ids back in so this run can check them straight
            // away, instead of finding a reply only on the next sync.
            sends = sends.map { send in
                guard let message = recovered.threadIDs[send.id] else { return send }
                return send.attaching(message: message)
            }

            beginStep(2)
            let checked = try await checkForReplies(in: sends,
                                                    excludingContactIDs: excludingContactIDs,
                                                    alwaysChecking: Set(recovered.threadIDs.keys),
                                                    retrying: forceFullCheck ? [] : checkpoint.retryThreadIDs,
                                                    since: since)
            outcome.replies = checked.replies
            outcome.failed += checked.failed
            outcome.read += checked.read
            var read: String
            if checked.threads == 0 {
                read = checked.wasFullCheck ? "No open threads to read" : "No open thread had new mail\(after)"
            } else {
                read = checked.wasFullCheck
                    ? "Read all \(checked.threads) open threads"
                    : "Read \(checked.threads) \(checked.threads == 1 ? "thread" : "threads") with new mail\(after)"
                read += " · \(checked.replies) \(checked.replies == 1 ? "reply" : "replies")"
                if !checked.bounces.isEmpty { read += " · \(checked.bounces.count) failure \(checked.bounces.count == 1 ? "notice" : "notices")" }
                if checked.gone > 0 { read += " · \(checked.gone) deleted in Gmail" }
            }
            note(record.id, Self.stepTitles[1], read, issues: ReplyCheckLog.issues(checked.reasons))
            beginStep(3)
            let confirmed = try await confirmThreadBounces(checked.bounces, emailByContact: emailByContact)
            outcome.bounced += confirmed.found
            outcome.failed += confirmed.failed
            outcome.read += confirmed.read
            note(record.id, Self.stepTitles[2],
                 checked.bounces.isEmpty ? "None in the threads read"
                    : "Read \(confirmed.read) · \(confirmed.found) \(confirmed.found == 1 ? "bounce" : "bounces")",
                 issues: confirmed.failed > 0 ? ["\(confirmed.failed) couldn't be read; tried again next check"] : [])
            // A thread that has a real answer in it isn't a dead address, even
            // if a failure notice sits in it too.
            for contactID in checked.repliedContacts { bounces[contactID] = nil }

            // Failure notices that never joined the mail's thread.
            beginStep(4)
            let scanned = try await scanInbox(sends: sends, emailByContact: emailByContact, since: noticesSince)
            outcome.bounced += scanned.found
            outcome.failed += scanned.failed
            outcome.read += scanned.read
            note(record.id, Self.stepTitles[3], Self.scanSummary(scanned, after: noticesAfter, noun: "failure notice", plural: "failure notices"),
                 issues: Self.scanIssues(scanned))

            // "No longer in service" answers from their side, wherever they are.
            beginStep(5)
            let dead = try await scanDeadAddressNotices(sends: sends, emailByContact: emailByContact, since: noticesSince)
            outcome.bounced += dead.found
            outcome.failed += dead.failed
            outcome.read += dead.read
            note(record.id, Self.stepTitles[4],
                 Self.scanSummary(dead, after: noticesAfter, noun: "“no longer here” reply", plural: "“no longer here” replies"),
                 issues: Self.scanIssues(dead))

            // Names for the people mailed that have none, from the account's own
            // mail: "Aryan Kadian <kdaryan@acme.com>" in anything from, to or
            // copying them.
            if !lookups.isEmpty {
                beginStep(6)
                count(lookups.count, "addresses")
                outcome.namesFound = await MailboxNames.shared.lookUp(lookups, accepting: RecipientName.isPersonEntry) {
                    [weak self] looked in self?.progress.done += looked
                }
                note(record.id, Self.stepTitles[5],
                     "Looked up \(lookups.count) \(lookups.count == 1 ? "address" : "addresses") · \(outcome.namesFound) named")
            }
            // Contacts already ruled out are dealt with.
            for id in excludingContactIDs { bounces[id] = nil }
            // Everything Gmail had when this check began has now been read —
            // if every read worked (`ReplyCheckpoint.complete`).
            // Threads a bounce notice in couldn't be read are read again too.
            var failedThreads = checked.failedThreadIDs
            for contactID in confirmed.unreadContacts {
                if let thread = sends.first(where: { $0.contactID == contactID })?.gmailThreadID {
                    failedThreads.insert(thread)
                }
            }
            checkpoint.complete(startedAt: startedAt, failedThreadIDs: failedThreads,
                                failedNotices: scanned.failed + dead.failed)
            checkpointFile?.save(checkpoint)
            saveBounces()
            // A run where every request failed (offline, Gmail down) read
            // nothing, and stamping it "Checked just now" would say the silence
            // on screen is current when it's just as stale as before.
            if outcome.readNothing {
                errorMessage = "Couldn't reach Gmail, so nothing was checked. Try again in a moment."
                checkLog.update(record.id) { $0.result = .stopped(errorMessage ?? "") }
            } else {
                completed = true
                checkLog.update(record.id) { $0.result = outcome.failed == 0 ? .complete : .incomplete }
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

    // MARK: - Timeline

    /// Record what one step of check `id` did.
    private func note(_ id: UUID, _ title: String, _ summary: String, issues: [String] = []) {
        checkLog.update(id) { $0.steps.append(.init(title: title, summary: summary, issues: issues)) }
        saveCheckLog()
    }

    private func saveCheckLog() {
        checkLogFile?.save(checkLog)
    }

    /// "3:04 PM", or "Oct 8, 3:04 PM" when it wasn't today.
    nonisolated static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// What an inbox search for notices found. `read` counts the search itself.
    nonisolated private static func scanSummary(_ scan: (found: Int, failed: Int, read: Int),
                                                after: String, noun: String, plural: String) -> String {
        guard scan.read > 0 else { return "Couldn't search" }
        let notices = scan.read - 1 + scan.failed
        let range = after.isEmpty ? " in the last 120 days" : after
        guard notices > 0 else { return "No new \(plural)\(range)" }
        return "\(notices) new \(notices == 1 ? noun : plural)\(range) · \(scan.found) \(scan.found == 1 ? "bounce" : "bounces")"
    }

    nonisolated private static func scanIssues(_ scan: (found: Int, failed: Int, read: Int)) -> [String] {
        if scan.read == 0 && scan.failed > 0 { return ["The search couldn't be run; tried again next check"] }
        return scan.failed > 0 ? ["\(scan.failed) couldn't be read; tried again next check"] : []
    }

    // MARK: - One mail

    /// What looking for one mail's bounce found.
    enum BounceCheck: Equatable {
        /// It bounced; the reason, in words. Now in the Bounced lane.
        case bounced(reason: String)
        /// Someone answered it, so it was delivered.
        case replied
        /// No failure notice for it anywhere in the mailbox.
        case clear
        case failed(String)
    }

    /// Look for one mail's bounce now, rather than waiting for the next sync:
    /// its own thread first, then failure notices anywhere in the mailbox
    /// (Spam and Trash included) that name its address. A bounce found is kept
    /// like any other — and one dismissed before comes back, since this was
    /// asked about by name.
    ///
    /// "No longer in service" answers from their side count too, in the
    /// thread or anywhere else: from the address, naming it, or from its
    /// company's domain when they were the one mailed there.
    ///
    /// - Parameters:
    ///   - sends, emailByContact: everyone mailed, so an answer from the
    ///     company's domain is only pinned on this person when it can't be
    ///     about anyone else.
    func checkBounce(of send: MailSend, address: String,
                     sends: [MailSend], emailByContact: [String: String]) async -> BounceCheck {
        guard let reader else { return .failed(GmailAuthError.notConnected.localizedDescription) }
        let address = address.lowercased()
        // Recorded as their reply before such answers were told apart.
        if send.hasReplied, BounceParsing.isDeadAddressNotice(subject: nil, text: send.replySnippet) {
            return keep(Bounce(contactID: send.contactID, address: address, at: send.repliedAt ?? .now,
                               snippet: send.replySnippet, status: nil, diagnostic: nil))
        }
        do {
            if let threadID = send.gmailThreadID {
                switch try await Self.firstResponse(inThread: threadID, after: send.sentAt, reader: reader) {
                case .reply:
                    return .replied
                case .bounce(let at, let messageID, let snippet):
                    let read = Self.isSafePathComponent(messageID)
                        ? try? await Self.readNotice(id: messageID, lookingUpOriginal: false, reader: reader)
                        : nil
                    if read != nil { seenBounceMessages.insert(messageID) }
                    let failures = read.map { $0.notice.failures(snippet: $0.snippet ?? snippet) } ?? []
                    // A notice that reads as a delay, or a success, isn't one.
                    if read == nil || !failures.isEmpty || read?.notice.isNotice == false {
                        let failure = failures.first { $0.address == address } ?? failures.first
                        return keep(Bounce(contactID: send.contactID, address: address, at: at,
                                           snippet: read?.snippet ?? snippet,
                                           status: failure?.status, diagnostic: failure?.diagnostic))
                    }
                case .silent:
                    break
                }
            }

            // Notices that never joined the thread, found by the address in them.
            guard Self.isSearchable(address) else { return .clear }
            let ids = try await Self.listBounceNotices(matching: "\"\(address)\"", limit: 20, reader: reader)
            for id in ids where Self.isSafePathComponent(id) {
                guard let notice = try? await Self.readNotice(id: id, lookingUpOriginal: true, reader: reader) else { continue }
                seenBounceMessages.insert(id)
                let failures = notice.notice.failures(snippet: notice.snippet)
                let isThisMail = notice.originalGmailID != nil && notice.originalGmailID == send.gmailMessageID
                guard let failure = failures.first(where: { $0.address == address }) ?? (isThisMail ? failures.first : nil) else {
                    continue
                }
                // A notice from before this mail went says nothing about it.
                if !isThisMail, let sentAt = send.sentAt, notice.at < sentAt.addingTimeInterval(-5 * 60) { continue }
                return keep(Bounce(contactID: send.contactID, address: address, at: notice.at, snippet: notice.snippet,
                                   status: failure.status, diagnostic: failure.diagnostic))
            }

            // "No longer in service" answers from them, naming them, or from
            // their company.
            let domain = address.split(separator: "@").last.map(String.init) ?? address
            let answers = try await Self.listBounceNotices(base: BounceParsing.deadAddressQuery,
                                                           matching: "{from:\(address) \"\(address)\" from:\(domain)}",
                                                           limit: 20, reader: reader)
            let mailed = Self.mailed(sends, emailByContact: emailByContact)
            for answer in try await readHeaders(ids: answers.filter(Self.isSafePathComponent)) {
                seenBounceMessages.insert(answer.id)
                guard !BounceParsing.isBounceSender(answer.from),
                      BounceParsing.isDeadAddressNotice(subject: answer.subject, text: answer.snippet),
                      BounceParsing.matchDeadAddressNotice(sender: answer.from, text: answer.snippet,
                                                           threadID: answer.threadID, at: answer.at,
                                                           mailed: mailed) == send.contactID else { continue }
                return keep(Bounce(contactID: send.contactID, address: address, at: answer.at,
                                   snippet: answer.snippet, status: nil, diagnostic: nil))
            }
            saveBounces()
            return .clear
        } catch let error as GmailAuthError where error.needsReconnect {
            needsReconnect = true
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.isCancellation ? "The check was cancelled." : error.localizedDescription)
        }
    }

    private func keep(_ bounce: Bounce) -> BounceCheck {
        dismissedBounces[bounce.contactID] = nil
        _ = record(bounce)
        saveBounces()
        return .bounced(reason: bounce.reason.label)
    }

    // MARK: - Pass 1: recover thread ids for older sends

    private struct Recovered {
        var threadIDs: [String: GmailAuthStore.SentMessage] = [:]
        var failed = 0
        var read = 0
        /// Sends without a thread id that were looked for, and of those, ones
        /// Sent doesn't have.
        var targets = 0
        var notFound = 0
        /// Why the failed ones failed, with how often.
        var reasons: [String: Int] = [:]
        var count: Int { threadIDs.count }
    }

    private enum RecoverResult {
        case attached(sendID: String, message: GmailAuthStore.SentMessage)
        case notFound(sendID: String)
        case skipped
        case failed(String)
    }

    private func recoverThreadIDs(in sends: [MailSend],
                                  emailByContact: [String: String]) async throws -> Recovered {
        guard let reader else { throw GmailAuthError.notConnected }
        let targets = sends.filter {
            $0.gmailThreadID == nil && $0.sentAt != nil && !unrecoverableSendIDs.contains($0.id)
        }
        guard !targets.isEmpty else { return Recovered() }

        count(targets.count, "mails")
        var result = Recovered()
        result.targets = targets.count

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
                            return .failed(ReplyCheckLog.reason(for: error))
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
                        result.reasons["Couldn't save it to the database", default: 0] += 1
                    }
                case .notFound(let sendID):
                    result.read += 1
                    result.notFound += 1
                    unrecoverableSendIDs.insert(sendID)
                case .skipped:
                    break
                case .failed(let reason):
                    result.failed += 1
                    result.reasons[reason, default: 0] += 1
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
        var failed = 0
        var read = 0
        var bounces: [FoundBounce] = []
        var repliedContacts: Set<String> = []
        /// Contacts whose threads were actually read this run.
        var checkedContacts: Set<String> = []
        var wasFullCheck = true
        /// Threads read, and of those, ones deleted in Gmail.
        var threads = 0
        var gone = 0
        /// Why the failed ones failed, with how often.
        var reasons: [String: Int] = [:]
        /// Threads that couldn't be read (or whose reply couldn't be saved),
        /// for the next check to read again.
        var failedThreadIDs: Set<String> = []
    }

    private enum CheckResult {
        case reply(sendID: String, threadID: String, contactID: String, at: Date, from: String, snippet: String?)
        case bounce(FoundBounce)
        case silent
        /// Deleted in Gmail: nothing to read, and nothing wrong.
        case gone(threadID: String)
        case failed(threadID: String, reason: String)
    }

    /// Threads that received mail from someone else since `date`, so a check
    /// reads only those. Read page by page, up to 5,000 messages; nil beyond
    /// that — then the caller can't tell what it's missing and reads everything.
    nonisolated private static func findIncomingThreadIDs(after date: Date,
                                                          reader: (String, [URLQueryItem]) async throws -> Data) async throws -> Set<String>? {
        struct Listing: Decodable {
            let messages: [GmailAuthStore.SentMessage]?
            let nextPageToken: String?
        }
        var threads = Set<String>()
        var pageToken: String?
        for _ in 0..<10 {
            var query = [URLQueryItem(name: "q", value: "after:\(Int(date.timeIntervalSince1970)) -from:me"),
                         URLQueryItem(name: "maxResults", value: "500")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let listing = try JSONDecoder().decode(Listing.self, from: try await reader("messages", query))
            threads.formUnion(listing.messages?.map(\.threadID) ?? [])
            guard let next = listing.nextPageToken else { return threads }
            pageToken = next
        }
        return nil
    }

    /// - Parameter alwaysChecking: sends to read even on a delta sync — ones whose
    ///   thread was only just recovered, and so has never been read at all.
    private func checkForReplies(in sends: [MailSend],
                                 excludingContactIDs: Set<String>,
                                 alwaysChecking: Set<String>,
                                 retrying: Set<String>,
                                 since: Date?) async throws -> Checked {
        guard let reader else { throw GmailAuthError.notConnected }
        let cutoff = Date().addingTimeInterval(-Self.checkWindow)
        let activeSends = sends.filter {
            $0.gmailThreadID != nil && !goneThreadIDs.contains($0.gmailThreadID ?? "") &&
            !$0.hasReplied &&
            !excludingContactIDs.contains($0.contactID) &&
            ($0.sentAt ?? .distantPast) > cutoff
        }
        guard !activeSends.isEmpty else { return Checked() }

        // Only threads that have had mail from anyone else since the last check
        // (`since`, which already carries the overlap) — or, on an account's
        // first check, in the 120 days sends are checked for. One search, then
        // a read per thread that has something new, instead of a read per open
        // thread. If the search fails or overflows, read every open thread.
        var result = Checked()
        let targets: [MailSend]
        if let incoming = try? await Self.findIncomingThreadIDs(after: since ?? cutoff, reader: reader) {
            result.wasFullCheck = false
            // Plus the ones the last check couldn't read.
            targets = activeSends.filter { send in
                alwaysChecking.contains(send.id)
                    || send.gmailThreadID.map { incoming.contains($0) || retrying.contains($0) } == true
            }
        } else {
            targets = activeSends
        }
        result.checkedContacts = Set(targets.map(\.contactID))
        result.threads = targets.count
        guard !targets.isEmpty else { return result }

        count(targets.count, "mails")

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
                                return .reply(sendID: send.id, threadID: threadID, contactID: send.contactID,
                                              at: date, from: sender, snippet: snippet)
                            case .bounce(let date, let messageID, let snippet):
                                return .bounce(FoundBounce(contactID: send.contactID, messageID: messageID,
                                                           at: date, snippet: snippet))
                            case .silent:
                                return .silent
                            }
                        } catch let error as GmailAuthError where error.endsRun {
                            throw error
                        } catch let error as SupabaseError where error.isSchemaOutOfDate {
                            throw error
                        } catch GmailAuthError.gone {
                            return .gone(threadID: threadID)
                        } catch {
                            return .failed(threadID: threadID, reason: ReplyCheckLog.reason(for: error))
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
                case .reply(let sendID, let threadID, let contactID, let date, let sender, let snippet):
                    result.read += 1
                    result.repliedContacts.insert(contactID)
                    do {
                        try await SupabaseAPI.recordReply(sendID: sendID, at: date,
                                                          from: sender, snippet: snippet)
                        result.replies += 1
                    } catch {
                        result.failed += 1
                        result.reasons["Couldn't save the reply to the database", default: 0] += 1
                        result.failedThreadIDs.insert(threadID)
                    }
                case .bounce(let found):
                    result.read += 1
                    result.bounces.append(found)
                case .silent:
                    result.read += 1
                case .gone(let threadID):
                    result.read += 1
                    result.gone += 1
                    goneThreadIDs.insert(threadID)
                case .failed(let threadID, let reason):
                    result.failed += 1
                    result.reasons[reason, default: 0] += 1
                    result.failedThreadIDs.insert(threadID)
                }
            }
            progress.done += chunk.count
        }
        return result
    }

    // MARK: - Pass 3: failure notices

    /// At most this many notices are listed per sync.
    nonisolated private static let bounceListLimit = 300

    /// A failure notice, read whole, and the send it names when that could be
    /// looked up.
    private struct ReadNotice {
        let id: String
        let at: Date
        let snippet: String?
        let notice: ParsedNotice
        /// Gmail's id for the original mail, found from the `Message-ID` the
        /// notice quotes back.
        let originalGmailID: String?
    }

    /// Read bounces found in their mail's own thread. The thread already names
    /// the send, but only the notice's report says whether it's a failure or a
    /// delay, and why. Each notice is read once: one already seen was dealt
    /// with on an earlier sync.
    private func confirmThreadBounces(_ found: [FoundBounce],
                                      emailByContact: [String: String]) async throws
        -> (found: Int, failed: Int, read: Int, unreadContacts: [String]) {
        let fresh = found.filter { !seenBounceMessages.contains($0.messageID) && Self.isSafePathComponent($0.messageID) }
        guard !fresh.isEmpty else { return (0, 0, 0, []) }
        count(fresh.count, "notices")
        let notices = try await readNotices(ids: fresh.map(\.messageID), lookingUpOriginals: false)
        var result = (found: 0, failed: 0, read: 0, unreadContacts: [String]())
        for bounce in fresh {
            guard let address = emailByContact[bounce.contactID]?.lowercased() else { continue }
            guard let read = notices[bounce.messageID] else {
                // Couldn't read it: go on what the thread showed, and read the
                // thread (and so the notice) again next time.
                result.failed += 1
                result.unreadContacts.append(bounce.contactID)
                if record(Bounce(contactID: bounce.contactID, address: address, at: bounce.at,
                                 snippet: bounce.snippet, status: nil, diagnostic: nil)) {
                    result.found += 1
                }
                continue
            }
            result.read += 1
            seenBounceMessages.insert(bounce.messageID)
            let failures = read.notice.failures(snippet: read.snippet ?? bounce.snippet)
            // A report that fails nobody — a delay, or a success — isn't a
            // bounce, even if it was taken for one before it could be read.
            guard !failures.isEmpty || !read.notice.isNotice else {
                if bounces[bounce.contactID]?.at == bounce.at { bounces[bounce.contactID] = nil }
                continue
            }
            let failure = failures.first { $0.address == address } ?? failures.first
            if record(Bounce(contactID: bounce.contactID, address: address, at: bounce.at,
                             snippet: read.snippet ?? bounce.snippet,
                             status: failure?.status, diagnostic: failure?.diagnostic)) {
                result.found += 1
            }
        }
        return result
    }

    /// Find failure notices that never joined the mail's thread — plenty of
    /// servers send theirs without the headers Gmail threads on — and match
    /// each to the send it's about. Only notices not read before are fetched,
    /// so after the first sync this is one small request.
    ///
    /// A notice is matched by the `Message-ID` it quotes back, which names the
    /// exact mail. When it doesn't quote one, or the mail can't be found, it's
    /// matched by address instead — and then only against a contact who was
    /// mailed before it arrived: an address that bounced for someone else,
    /// months ago, says nothing about this send.
    private func scanInbox(sends: [MailSend], emailByContact: [String: String],
                           since: Date?) async throws -> (found: Int, failed: Int, read: Int) {
        guard let reader else { throw GmailAuthError.notConnected }
        var contactsByAddress: [String: [String]] = [:]
        for (contactID, address) in emailByContact {
            contactsByAddress[address.lowercased(), default: []].append(contactID)
        }
        var sentAtByContact: [String: [Date]] = [:]
        var contactByGmailID: [String: String] = [:]
        for send in sends {
            if let at = send.sentAt { sentAtByContact[send.contactID, default: []].append(at) }
            if let id = send.gmailMessageID { contactByGmailID[id] = send.contactID }
        }

        let ids: [String]
        do {
            ids = try await Self.listBounceNotices(matching: ReplyCheckpoint.searchTerm(after: since), reader: reader)
        } catch let error as GmailAuthError where error.endsRun {
            throw error
        } catch {
            return (0, 1, 0)
        }
        let unread = ids.filter { !seenBounceMessages.contains($0) && Self.isSafePathComponent($0) }
        guard !unread.isEmpty else { return (0, 0, 1) }

        count(unread.count, "notices")
        let notices = try await readNotices(ids: unread, lookingUpOriginals: true)
        var found = 0, read = 1
        let failed = unread.count - notices.count
        for id in unread {
            guard let notice = notices[id] else { continue }
            read += 1
            seenBounceMessages.insert(id)
            let failures = notice.notice.failures(snippet: notice.snippet)
            guard !failures.isEmpty else { continue }

            // The exact send, by the Message-ID the notice quoted. Our sends go
            // to one person each, so any failure in it is theirs.
            if let original = notice.originalGmailID,
               let contactID = contactByGmailID[original],
               let address = emailByContact[contactID]?.lowercased() {
                let failure = failures.first { $0.address == address } ?? failures[0]
                if record(Bounce(contactID: contactID, address: address, at: notice.at, snippet: notice.snippet,
                                 status: failure.status, diagnostic: failure.diagnostic)) {
                    found += 1
                }
                continue
            }

            for failure in failures {
                for contactID in contactsByAddress[failure.address] ?? [] {
                    // Mailed before the notice came (a few minutes' slack for clocks).
                    let mailedBefore = sentAtByContact[contactID]?.contains { $0 <= notice.at.addingTimeInterval(5 * 60) } ?? false
                    guard mailedBefore else { continue }
                    if record(Bounce(contactID: contactID, address: failure.address, at: notice.at, snippet: notice.snippet,
                                     status: failure.status, diagnostic: failure.diagnostic)) {
                        found += 1
                    }
                }
            }
        }
        return (found, failed, read)
    }

    // MARK: - Pass 4: "no longer in service"

    /// Everyone mailed, for matching an answer to the person it's about.
    private static func mailed(_ sends: [MailSend], emailByContact: [String: String]) -> [BounceParsing.Mailed] {
        sends.compactMap { send -> BounceParsing.Mailed? in
            guard let at = send.sentAt, let address = emailByContact[send.contactID]?.lowercased() else { return nil }
            return BounceParsing.Mailed(contactID: send.contactID, address: address, sentAt: at, threadID: send.gmailThreadID)
        }
        .sorted { $0.sentAt < $1.sentAt }
    }

    /// Answers from the recipient's side saying the address is dead — "no
    /// longer in service", "no longer with the company", "this mailbox isn't
    /// monitored" — wherever they landed: in the mail's thread or not, from
    /// the dead mailbox itself, a colleague, or the company's `noreply@`. Each
    /// is matched to the person it's about (`BounceParsing.matchDeadAddressNotice`)
    /// and kept as their bounce. Read once each, like failure notices.
    private func scanDeadAddressNotices(sends: [MailSend], emailByContact: [String: String],
                                        since: Date?) async throws -> (found: Int, failed: Int, read: Int) {
        guard let reader else { throw GmailAuthError.notConnected }
        let mailed = Self.mailed(sends, emailByContact: emailByContact)
        guard !mailed.isEmpty else { return (0, 0, 0) }

        let ids: [String]
        do {
            ids = try await Self.listBounceNotices(base: BounceParsing.deadAddressQuery, matching: ReplyCheckpoint.searchTerm(after: since),
                                                   limit: 100, reader: reader)
        } catch let error as GmailAuthError where error.endsRun {
            throw error
        } catch {
            return (0, 1, 0)
        }
        let unread = ids.filter { !seenBounceMessages.contains($0) && Self.isSafePathComponent($0) }
        guard !unread.isEmpty else { return (0, 0, 1) }

        count(unread.count, "messages")
        let answers = try await readHeaders(ids: unread)
        var found = 0, read = 1
        for answer in answers {
            read += 1
            seenBounceMessages.insert(answer.id)
            if keepDeadAddressNotice(answer, mailed: mailed, emailByContact: emailByContact) != nil { found += 1 }
        }
        return (found, unread.count - answers.count, read)
    }

    /// Keep `answer` as a bounce if it says an address is dead and can be
    /// pinned on one person mailed. The contact it was kept for, if any.
    @discardableResult
    private func keepDeadAddressNotice(_ answer: HeaderMessage, mailed: [BounceParsing.Mailed],
                                       emailByContact: [String: String]) -> String? {
        // The daemon's notices are read whole elsewhere.
        guard !BounceParsing.isBounceSender(answer.from),
              BounceParsing.isDeadAddressNotice(subject: answer.subject, text: answer.snippet),
              let contactID = BounceParsing.matchDeadAddressNotice(sender: answer.from, text: answer.snippet,
                                                                   threadID: answer.threadID, at: answer.at,
                                                                   mailed: mailed),
              let address = emailByContact[contactID]?.lowercased() else { return nil }
        return record(Bounce(contactID: contactID, address: address, at: answer.at, snippet: answer.snippet,
                             status: nil, diagnostic: nil)) ? contactID : nil
    }

    /// Replies recorded before "no longer in service" answers were told apart:
    /// each is taken back in the send history and kept as a bounce instead.
    /// The ids of the sends corrected — ones whose write failed are left as
    /// they are, to try again next sync.
    private func correctMisreadReplies(in sends: [MailSend], emailByContact: [String: String]) async -> Set<String> {
        var corrected: Set<String> = []
        for send in sends where send.hasReplied {
            guard BounceParsing.isDeadAddressNotice(subject: nil, text: send.replySnippet),
                  let at = send.repliedAt,
                  let address = emailByContact[send.contactID]?.lowercased() else { continue }
            do {
                try await SupabaseAPI.clearReply(sendID: send.id)
            } catch {
                continue
            }
            corrected.insert(send.id)
            dismissedBounces[send.contactID] = nil
            _ = record(Bounce(contactID: send.contactID, address: address, at: at, snippet: send.replySnippet,
                              status: nil, diagnostic: nil))
        }
        if !corrected.isEmpty { saveBounces() }
        return corrected
    }

    /// The parts of a message these checks read: who it's from, its subject,
    /// its opening lines, its thread and when it came.
    nonisolated struct HeaderMessage {
        let id: String
        let threadID: String?
        let from: String?
        let subject: String?
        let snippet: String?
        let at: Date
    }

    /// Read messages' headers and opening lines, a few at a time. One that
    /// couldn't be read is left out, to be tried next time.
    private func readHeaders(ids: [String]) async throws -> [HeaderMessage] {
        guard let reader else { throw GmailAuthError.notConnected }
        var result: [HeaderMessage] = []
        for chunk in stride(from: 0, to: ids.count, by: Self.concurrency).map({
            Array(ids[$0..<min($0 + Self.concurrency, ids.count)])
        }) {
            try Task.checkCancellation()
            let read = try await withThrowingTaskGroup(of: HeaderMessage?.self) { group in
                for id in chunk {
                    group.addTask {
                        do {
                            return try await Self.readHeaderMessage(id: id, reader: reader)
                        } catch let error as GmailAuthError where error.endsRun {
                            throw error
                        } catch {
                            return nil
                        }
                    }
                }
                var messages: [HeaderMessage] = []
                for try await message in group { if let message { messages.append(message) } }
                return messages
            }
            result += read
            progress.done += chunk.count
        }
        return result
    }

    nonisolated private static func readHeaderMessage(id: String,
                                                      reader: (String, [URLQueryItem]) async throws -> Data) async throws -> HeaderMessage {
        struct Raw: Decodable {
            let id: String
            let threadId: String?
            let snippet: String?
            let internalDate: String?
            let payload: GmailThread.Message.Payload?
        }
        let message = try JSONDecoder().decode(Raw.self, from: try await reader("messages/\(id)", [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "fields", value: "id,threadId,snippet,internalDate,payload/headers")
        ]))
        func header(_ name: String) -> String? {
            message.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let at = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        return HeaderMessage(id: message.id, threadID: message.threadId, from: header("From"),
                             subject: header("Subject"), snippet: message.snippet?.htmlUnescaped, at: at)
    }

    /// Read notices whole, a few at a time. A notice that couldn't be read is
    /// left out of the answer, to be tried again on the next sync.
    ///
    /// - Parameter lookingUpOriginals: also find each notice's original mail in
    ///   Gmail by the `Message-ID` it quotes — one small search per notice that
    ///   fails someone.
    private func readNotices(ids: [String], lookingUpOriginals: Bool) async throws -> [String: ReadNotice] {
        guard let reader else { throw GmailAuthError.notConnected }
        var result: [String: ReadNotice] = [:]
        for chunk in stride(from: 0, to: ids.count, by: Self.concurrency).map({
            Array(ids[$0..<min($0 + Self.concurrency, ids.count)])
        }) {
            try Task.checkCancellation()
            let read = try await withThrowingTaskGroup(of: ReadNotice?.self) { group in
                for id in chunk {
                    group.addTask {
                        do {
                            return try await Self.readNotice(id: id, lookingUpOriginal: lookingUpOriginals, reader: reader)
                        } catch let error as GmailAuthError where error.endsRun {
                            throw error
                        } catch {
                            return nil
                        }
                    }
                }
                var notices: [ReadNotice] = []
                for try await notice in group { if let notice { notices.append(notice) } }
                return notices
            }
            for notice in read { result[notice.id] = notice }
            progress.done += chunk.count
        }
        return result
    }

    /// The ids of recent failure notices, newest first — Spam and Trash
    /// included, where a notice filtered or deleted by hand would otherwise
    /// never be seen.
    nonisolated private static func listBounceNotices(base: String = BounceParsing.noticeQuery,
                                                      matching terms: String? = nil, limit: Int = bounceListLimit,
                                                      reader: (String, [URLQueryItem]) async throws -> Data) async throws -> [String] {
        struct Listing: Decodable {
            struct Item: Decodable { let id: String }
            let messages: [Item]?
            let nextPageToken: String?
        }
        var ids: [String] = []
        var pageToken: String?
        repeat {
            let search = [base, terms].compactMap { $0 }.joined(separator: " ")
            var query = [URLQueryItem(name: "q", value: search),
                         URLQueryItem(name: "includeSpamTrash", value: "true"),
                         URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let listing = try JSONDecoder().decode(Listing.self, from: try await reader("messages", query))
            ids += listing.messages?.map(\.id) ?? []
            pageToken = listing.nextPageToken
        } while pageToken != nil && ids.count < limit
        return Array(ids.prefix(limit))
    }

    /// One notice, whole: `format=raw` is the only form that keeps the report
    /// and the quoted headers intact. Notices are small — a few kilobytes of
    /// prose and headers, plus the text of the mail that bounced.
    nonisolated private static func readNotice(id: String, lookingUpOriginal: Bool,
                                               reader: (String, [URLQueryItem]) async throws -> Data) async throws -> ReadNotice? {
        struct Raw: Decodable {
            let id: String
            let snippet: String?
            let internalDate: String?
            let raw: String?
        }
        let message = try JSONDecoder().decode(Raw.self, from: try await reader("messages/\(id)", [
            URLQueryItem(name: "format", value: "raw"),
            URLQueryItem(name: "fields", value: "id,snippet,internalDate,raw")
        ]))
        guard let raw = message.raw, let notice = BounceParsing.parseNotice(base64URL: raw) else { return nil }
        let at = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        let snippet = message.snippet?.htmlUnescaped

        var original: String?
        if lookingUpOriginal, let messageID = notice.originalMessageID,
           !notice.failures(snippet: snippet).isEmpty {
            // Not being able to look it up only loses the exact match; the
            // address match still runs.
            original = try? await findMessage(rfc822ID: messageID, reader: reader)
        }
        return ReadNotice(id: message.id, at: at, snippet: snippet, notice: notice, originalGmailID: original)
    }

    /// Gmail's id for the mail with this `Message-ID`, if it's in the mailbox.
    nonisolated private static func findMessage(rfc822ID: String,
                                                reader: (String, [URLQueryItem]) async throws -> Data) async throws -> String? {
        struct Listing: Decodable {
            struct Item: Decodable { let id: String }
            let messages: [Item]?
        }
        let data = try await reader("messages", [
            URLQueryItem(name: "q", value: "rfc822msgid:\(rfc822ID)"),
            URLQueryItem(name: "maxResults", value: "1")
        ])
        return try JSONDecoder().decode(Listing.self, from: data).messages?.first?.id
    }

    private enum ThreadResponse {
        case reply(at: Date, from: String, snippet: String?)
        /// The only thing that came back was a delivery failure.
        case bounce(at: Date, messageID: String, snippet: String?)
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
            URLQueryItem(name: "metadataHeaders", value: "Precedence"),
            URLQueryItem(name: "metadataHeaders", value: "Subject")
        ])
        let thread = try JSONDecoder().decode(GmailThread.self, from: data)

        // Fast-path: if the thread only has our own single send, nobody answered.
        if thread.messages.count <= 1 && (thread.messages.first?.isOurs ?? false) {
            return .silent
        }

        var bounce: GmailThread.Message?
        // Oldest first, so the first qualifying message is the first reply.
        for message in thread.messages.sorted(by: { $0.date < $1.date }) {
            guard !message.isOurs else { continue }
            if let sentAt, message.date < sentAt.addingTimeInterval(-30) { continue }
            if message.isBounce {
                // A "still trying" notice is neither an answer nor a bounce.
                if !message.isDelay { bounce = message }
                continue
            }
            // "This address is no longer in service", from their side: reads
            // like a reply, but it's a bounce.
            if message.isDeadAddressNotice {
                if bounce == nil { bounce = message }
                continue
            }
            if message.isAutomated { continue }
            guard let from = message.from, !from.isEmpty else { continue }
            return .reply(at: message.date,
                          from: from,
                          snippet: message.snippet?.htmlUnescaped)
        }
        if let bounce { return .bounce(at: bounce.date, messageID: bounce.id, snippet: bounce.snippet?.htmlUnescaped) }
        return .silent
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

        /// A delivery notice — the opposite of a reply, and when it's a
        /// failure rather than a delay, a strong hint the address is dead.
        var isBounce: Bool { BounceParsing.isBounceSender(from) }
        var isDelay: Bool { BounceParsing.isDelay(subject: header("Subject"), snippet: snippet) }
        var isDeadAddressNotice: Bool {
            BounceParsing.isDeadAddressNotice(subject: header("Subject"), text: snippet?.htmlUnescaped)
        }

        func header(_ name: String) -> String? {
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

/// A bounce seen in a mail's thread, before it's matched to an address.
nonisolated struct FoundBounce {
    let contactID: String
    /// The notice's Gmail id, to read it whole.
    let messageID: String
    let at: Date
    let snippet: String?
}
