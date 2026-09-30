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
