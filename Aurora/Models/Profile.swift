import Foundation

/// The user's own profile details, stored in Supabase keyed by their Gmail
/// address so it follows them across devices.
struct Profile: Codable, Equatable {
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
    var repliedAt: Date?
    var replyFrom: String?
    var replySnippet: String?

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
        case sealed
        case sealedReply = "sealed_reply"
    }

    /// Every reply column is optional at the decoder level, not just in Swift:
    /// they arrive only once the schema migration in the README has been run, and
    /// the app has to keep working (minus reply data) until then.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contactID = try c.decode(String.self, forKey: .contactID)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        gmailMessageID = try c.decodeIfPresent(String.self, forKey: .gmailMessageID)
        gmailThreadID = try c.decodeIfPresent(String.self, forKey: .gmailThreadID)
        repliedAt = try c.decodeIfPresent(Date.self, forKey: .repliedAt)
        // Sealed under the account key once the account is set up; plain on a
        // row from before. A seal that won't open (a key since replaced) reads
        // as no text — the send itself, and that it was sent, still count.
        if let sealed = try c.decodeIfPresent(String.self, forKey: .sealed) {
            let mail = KeyRing.shared.openPersonal(SealedMail.self, from: sealed, context: Sealing.sendContext(id: id))
            subject = mail?.subject
            body = mail?.body
        } else {
            subject = try c.decodeIfPresent(String.self, forKey: .subject)
            body = try c.decodeIfPresent(String.self, forKey: .body)
        }
        if let sealed = try c.decodeIfPresent(String.self, forKey: .sealedReply) {
            let reply = KeyRing.shared.openPersonal(SealedReply.self, from: sealed, context: Sealing.replyContext(id: id))
            replyFrom = reply?.from
            replySnippet = reply?.snippet
        } else {
            replyFrom = try c.decodeIfPresent(String.self, forKey: .replyFrom)
            replySnippet = try c.decodeIfPresent(String.self, forKey: .replySnippet)
        }
    }
}

// MARK: - Sealed parts of the user's own rows

/// A sent mail's subject and body, as sealed into `mail_sends.sealed`.
nonisolated struct SealedMail: Codable {
    var subject: String?
    var body: String?
}

/// Who answered a send and what they said, as sealed into `mail_sends.sealed_reply`.
nonisolated struct SealedReply: Codable {
    var from: String?
    var snippet: String?
}

/// A template's text, as sealed into `templates.sealed`.
nonisolated struct SealedTemplate: Codable {
    var name: String
    var subject: String
    var content: String
}
