import Foundation

/// One send, as the queue keeps it: the templates it's written from and the
/// people it goes to — never the finished mails.
///
/// Each mail is written the moment it's about to go out (`QueuedMail.rendered`),
/// from exactly what was on screen when Send or Schedule was tapped: the
/// template text is copied in, not looked up, so editing a template afterwards
/// can't change a batch that's already been reviewed. What's saved is a few
/// hundred bytes a person, so a batch of hundreds costs next to nothing to keep,
/// and nothing to load until it's sent.
///
/// Saved to disk after every change (see `MailQueue`), which is what lets a batch
/// survive the app closing: it comes back paused, to be resumed.
struct MailBatch: Codable, Identifiable {
    let id: UUID
    /// Which group this is — "Adobe", "Not mailed yet".
    var title: String
    let createdAt: Date
    /// When it's due to go. Nil for "now".
    var scheduledFor: Date?
    /// When the queue first began sending it. A scheduled batch that hasn't
    /// started is still waiting for its time; one that has was interrupted.
    var startedAt: Date?
    /// Stopped by the user, or found half-sent when the app opened.
    var isPaused = false
    /// Why the queue stopped it, when the queue did (Gmail refused the account,
    /// the connection dropped, the app closed mid-send) — shown on the batch
    /// until it's resumed. Nil when the user paused it, or it never stopped.
    var pauseReason: String?
    /// When the queue carries on by itself: set when Gmail's sending limit
    /// stopped the batch with a known (or a sensible) time to try again.
    /// Cleared by anything the user does to the batch.
    var resumeAt: Date?
    /// How many times in a row the queue has retried this batch by itself after
    /// a dropped connection or a Gmail failure. Cleared by a mail going out.
    var retries: Int?
    /// Why it stopped, in a few words, for the Live Activity: "Connection lost".
    var stopNote: String?
    var fromName: String
    var templates: [MailTemplate.ID: TemplateSnapshot]
    var mails: [QueuedMail]

    /// The template text as it read when the batch was confirmed.
    struct TemplateSnapshot: Codable {
        let name: String
        let subject: String
        let content: String
    }

    var pending: Int { mails.count { $0.status.isWaiting } }
    var sent: Int { mails.count { $0.status.isSent } }
    var failed: Int { mails.count { $0.status.isFailed } }
    var hasWork: Bool { mails.contains { $0.status.isWaiting } }

    /// Waiting for its time: scheduled, not yet started, and not yet due.
    func isScheduled(at now: Date = .now) -> Bool {
        guard let scheduledFor, startedAt == nil, hasWork, !isPaused else { return false }
        return scheduledFor > now
    }

    /// Scheduled, due, and not yet confirmed — the one state that asks before it
    /// sends.
    func isDue(at now: Date = .now) -> Bool {
        guard let scheduledFor, startedAt == nil, hasWork, !isPaused else { return false }
        return scheduledFor <= now
    }

    /// Everything in it has been dealt with, one way or the other.
    var isFinished: Bool { !hasWork }

    /// The names of the templates it's written from, for a summary line.
    var templateNames: [String] {
        let used = Set(mails.compactMap { $0.override == nil ? $0.templateID : nil })
        return templates.filter { used.contains($0.key) }.map(\.value.name).sorted()
    }

    var companies: Set<String> { Set(mails.map(\.company)) }

    /// The mail going out now, else the next to go.
    var current: QueuedMail? {
        mails.first { if case .sending = $0.status { true } else { false } }
            ?? mails.first(where: \.status.isWaiting)
    }

    /// Who the batch is to, by company: "ACKO Insurance", or "ACKO Insurance
    /// and 5 more" — in the order they're mailed. A batch's own name is often
    /// the rule that picked it ("First outreach"), which says nothing about
    /// who's being written to.
    var companiesLabel: String {
        var seen = Set<String>()
        let ordered = mails.map(\.company).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard let first = ordered.first else { return title }
        return ordered.count == 1 ? first : "\(first) and \(ordered.count - 1) more"
    }

    /// The company the mail going out now (or next) is to; once none is
    /// left, `companiesLabel`.
    var liveCompany: String {
        guard let company = current?.company, !company.isEmpty else { return companiesLabel }
        return company
    }

    /// Why its mails failed: each distinct reason, explained, with how many
    /// failed for it — commonest first.
    var failureReasons: [(reason: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for mail in mails {
            guard case .failed(let raw) = mail.status else { continue }
            let reason = QueuedMail.explain(raw)
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }.sorted { $0.count > $1.count }
    }

    /// The same in one line, for the shelf: the commonest reason, and how many
    /// failed for something else.
    var failureSummary: String? {
        let reasons = failureReasons
        guard let top = reasons.first else { return nil }
        let others = reasons.dropFirst().reduce(0) { $0 + $1.count }
        return others == 0 ? top.reason : "\(top.reason) +\(others) more"
    }
}

/// One person in a batch, and where their mail has got to.
struct QueuedMail: Codable, Identifiable {
    let id: Contact.ID
    let recipient: String
    let displayName: String
    let company: String
    /// What each placeholder fills in with for this person, keyed by the
    /// placeholder's token. Worked out when the batch was confirmed.
    let values: [String: String]
    var templateID: MailTemplate.ID?
    /// Written by hand on the compose screen; sent as is.
    var override: Override?
    var status: Status

    struct Override: Codable {
        let subject: String
        let body: String
    }

    enum Status: Codable, Equatable {
        case pending
        /// Handed to Gmail at `since` and not yet answered. Found like this when
        /// the app opens, the app was closed mid-send, and whether it went out has
        /// to be checked in Gmail's Sent mail before anything else happens to it.
        case sending(since: Date)
        /// Delivered. `recorded` once it's in the send history — until then it's a
        /// contact the app would offer to mail again, so it's retried.
        case sent(at: Date, messageID: String?, threadID: String?, recorded: Bool)
        case failed(reason: String)

        /// Still to go out — including one whose fate is being checked.
        var isWaiting: Bool {
            switch self {
            case .pending, .sending: true
            default: false
            }
        }

        var isSent: Bool {
            if case .sent = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        /// Delivered, but not in the send history yet.
        var isUnrecorded: Bool {
            if case .sent(_, _, _, false) = self { return true }
            return false
        }

        /// Not sent and not in Gmail's hands: safe to take out of the queue.
        /// A mail cut off mid-send may have gone, so it stays until checked.
        var isRemovable: Bool {
            switch self {
            case .pending, .failed: true
            default: false
            }
        }
    }

    /// A failure reason as a person can act on it.
    ///
    /// Gmail's own sentence is kept where it already says what to do; the
    /// common ones are said plainly. A reason recorded before the queue could
    /// read Gmail's errors is only "{" — the first line of the JSON they came
    /// in — and is said to be lost rather than shown as is.
    static func explain(_ reason: String) -> String {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if text.isEmpty || text.hasPrefix("{") || text.hasPrefix("[") {
            return "Gmail refused it, but its reason wasn't kept. Retry to see why."
        }
        if lower.contains("invalid to header") || lower.contains("invalid recipient")
            || lower.contains("invalid email") {
            return "Gmail won't take this address. Check it, or mark the contact invalid."
        }
        if lower.contains("limit exceeded") || lower.contains("rate limit") || lower.contains("quota") {
            return "Gmail's sending limit for your account was reached. Retry in a few hours."
        }
        if lower.contains("mail service not enabled") {
            return "Sending is turned off for this Gmail account."
        }
        return text
    }

    init(id: Contact.ID, recipient: String, displayName: String, company: String,
         context: MailContext, templateID: MailTemplate.ID?, override: Override?) {
        self.id = id
        self.recipient = recipient
        self.displayName = displayName
        self.company = company
        self.values = Dictionary(uniqueKeysWithValues: context.values.map { ($0.key.token, $0.value) })
        self.templateID = templateID
        self.override = override
        self.status = .pending
    }

    var context: MailContext {
        MailContext(values: Dictionary(uniqueKeysWithValues: values.compactMap { token, value in
            MailPlaceholder(rawValue: token).map { ($0, value) }
        }))
    }

    /// The mail itself, written now. Nil when there's nothing to write it from.
    func rendered(in batch: MailBatch) -> (subject: String, body: String)? {
        if let override { return (override.subject, override.body) }
        guard let templateID, let template = batch.templates[templateID] else { return nil }
        let context = context
        return (context.fill(template.subject), context.fill(template.content))
    }
}
