import Foundation

/// The user's own profile details, stored in Supabase keyed by their Gmail
/// address so it follows them across devices.
struct Profile: Codable {
    var name = ""

    var isStudying = false
    var college = ""

    var isWorking = false
    var company = ""
    var position = ""

    var resumeLink = ""

    enum CodingKeys: String, CodingKey {
        case name
        case isStudying = "is_studying"
        case college
        case isWorking = "is_working"
        case company
        case position
        case resumeLink = "resume_link"
    }

    init() {}

    /// Rows may omit columns; decode leniently so a partial row still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isStudying = try c.decodeIfPresent(Bool.self, forKey: .isStudying) ?? false
        college = try c.decodeIfPresent(String.self, forKey: .college) ?? ""
        isWorking = try c.decodeIfPresent(Bool.self, forKey: .isWorking) ?? false
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        resumeLink = try c.decodeIfPresent(String.self, forKey: .resumeLink) ?? ""
    }
}

/// One "sent" record: this Gmail user sent a mail to this contact. Each send
/// is its own row, so the same contact can have many (the send history).
struct MailSend: Decodable, Identifiable {
    let id: String
    let contactID: String
    let sentAt: Date?
    let subject: String?
    let body: String?

    /// Gmail's own handles for the message this row records. `threadID` is what
    /// reply detection runs on; both are nil for sends made before the app
    /// started capturing them (see `ReplySync.recoverThreadIDs`).
    var gmailMessageID: String?
    var gmailThreadID: String?

    /// When someone other than the sender first wrote back in that thread, and
    /// who. Nil while a send is still unanswered.
    let repliedAt: Date?
    let replyFrom: String?
    let replySnippet: String?

    var hasReplied: Bool { repliedAt != nil }

    /// A copy carrying the ids just recovered from the Sent mailbox, so a sync
    /// that recovers a thread can check it for replies in the same pass.
    func attaching(message: GmailAuthStore.SentMessage) -> MailSend {
        var copy = self
        copy.gmailMessageID = message.id
        copy.gmailThreadID = message.threadID
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case contactID = "recruiter_id"
        case sentAt = "sent_at"
        case subject, body
        case gmailMessageID = "gmail_message_id"
        case gmailThreadID = "gmail_thread_id"
        case repliedAt = "replied_at"
        case replyFrom = "reply_from"
        case replySnippet = "reply_snippet"
    }

    /// Every reply column is optional at the decoder level, not just in Swift:
    /// they arrive only once the schema migration in the README has been run, and
    /// the app has to keep working (minus reply data) until then.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contactID = try c.decode(String.self, forKey: .contactID)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        gmailMessageID = try c.decodeIfPresent(String.self, forKey: .gmailMessageID)
        gmailThreadID = try c.decodeIfPresent(String.self, forKey: .gmailThreadID)
        repliedAt = try c.decodeIfPresent(Date.self, forKey: .repliedAt)
        replyFrom = try c.decodeIfPresent(String.self, forKey: .replyFrom)
        replySnippet = try c.decodeIfPresent(String.self, forKey: .replySnippet)
    }
}
