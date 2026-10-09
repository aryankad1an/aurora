import Foundation

/// A person at a company, backed by a Supabase `recruiters` row. `id` is the
/// row's UUID (empty for a not-yet-saved draft).
struct Contact: Identifiable, Decodable {
    var id: String = ""

    var email = ""
    var name = ""
    var phone: String?
    var position = ""
    /// What to put after "Hi " when mailing this person. Set it when the `name`
    /// field can't produce a good greeting on its own — an initial-first row
    /// ("A Bagarwal"), a role mailbox, a name filed surname-first. Left null the
    /// greeting is derived from `name` and `email` instead, so most rows never
    /// need one. See `greeting`.
    var greetingName: String?
    /// False when the address bounces or the person has left the company. Part of
    /// the shared contact row, not per-user: a dead address is dead for everyone.
    /// Invalid contacts are never suggested and can't be mailed — see
    /// `JobStore.setValidity`.
    var isValid = true
    // Sent state is per-user (from `mail_sends`), overlaid after decoding —
    // never part of the shared contact row.
    var isSent = false
    var sentAt: Date?        // when it was sent
    var sentSubject: String? // the rendered subject that went out
    var sentBody: String?    // the rendered body that went out
    /// Reply state for the latest send, overlaid from `mail_sends` alongside the
    /// sent state above. Per-user for the same reason: whether a contact wrote
    /// back is a fact about this user's mailbox, not about the shared contact.
    var repliedAt: Date?
    var replyFrom: String?
    var replySnippet: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, phone, position
        case greetingName = "greeting_name"
        case isValid = "is_valid"
    }

    init(id: String = "", email: String = "", name: String = "", phone: String? = nil,
         position: String = "", greetingName: String? = nil,
         isValid: Bool = true, isSent: Bool = false, sentAt: Date? = nil,
         sentSubject: String? = nil, sentBody: String? = nil,
         repliedAt: Date? = nil, replyFrom: String? = nil, replySnippet: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.phone = phone
        self.position = position
        self.greetingName = greetingName
        self.isValid = isValid
        self.isSent = isSent
        self.sentAt = sentAt
        self.sentSubject = sentSubject
        self.sentBody = sentBody
        self.repliedAt = repliedAt
        self.replyFrom = replyFrom
        self.replySnippet = replySnippet
    }

    /// The word that goes after "Hi " in a mail to this person: the stored
    /// `greetingName` when there is one, and otherwise whatever `RecipientName`
    /// can recover from the name, the name they signed a reply with, the name
    /// their address carries in this account's mail, and the address. Every
    /// greeting in the app runs through here, so overriding one row fixes it
    /// everywhere at once.
    var greeting: String {
        let override = greetingName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard override.isEmpty else { return override }
        return RecipientName.greeting(name: name, email: email, replyFrom: replyFrom,
                                      mailboxEntry: MailboxNames.shared.entry(for: email))
    }

    /// Whether this contact has nothing better than its address to be greeted
    /// by, and so is worth looking up in the account's mail.
    var needsNameLookup: Bool {
        RecipientName.needsLookup(name: name, email: email, greetingName: greetingName)
    }

    /// What to call this contact on screen: their name, or their address when
    /// the row has no name.
    var displayName: String { name.isEmpty ? email : name }

    /// Whether a mail can go to this contact at all: an address on file, and not
    /// ruled out. The one bar every send in the app holds — Suggested, the send
    /// chooser, a selection's Send, the compose screen and the follow-up queue.
    var isMailable: Bool { isValid && email.contains("@") }

    /// Whether this contact answers a (trimmed, non-empty) search — by name,
    /// address or position. `Job.matches` runs the same test over its people.
    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || email.localizedCaseInsensitiveContains(query)
            || position.localizedCaseInsensitiveContains(query)
    }

    /// Whether this contact wrote back to the last mail we sent them.
    var hasReplied: Bool { repliedAt != nil }

    /// What they said, without the quoted mail Gmail's snippet runs on into.
    /// Nil when no preview was captured.
    var replyPreview: String? {
        guard let snippet = replySnippet?.withoutQuoteHeader, !snippet.isEmpty else { return nil }
        return snippet
    }

    /// Rows carry nulls for optional columns, so decode leniently and default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        // Absent entirely until the `greeting_name` migration has been run.
        greetingName = try c.decodeIfPresent(String.self, forKey: .greetingName)
        // Rows written before the column existed come back null — those are valid.
        isValid = try c.decodeIfPresent(Bool.self, forKey: .isValid) ?? true
    }
}

/// The rendered mail that was actually sent to a contact.
struct SentMail {
    let subject: String
    let body: String
    /// What Gmail called the message it just sent. `threadID` is the handle reply
    /// detection is built on — every reply lands in the same thread, whoever sends
    /// it — so it's captured at send time rather than searched for afterwards.
    var gmailMessageID: String?
    var gmailThreadID: String?
}

/// One entry in the Activity feed: a single mail the user sent, with the
/// contact, company name, and that send's subject/body/date. One per send (so
/// repeat sends to the same contact are separate rows). Built from the send
/// history directly, so it stays visible even after the company leaves Home.
struct ActivityEntry: Identifiable {
    let id: String        // the send's id (unique per send)
    let company: String
    let contact: Contact
    var date: Date? { contact.sentAt }
}

/// One company in the catalog, backed by a Supabase `companies` row, with its
/// contacts (the embedded `recruiters` rows).
struct Job: Identifiable, Decodable {
    var id: String = ""
    var company: String
    /// The company's sector/industry, when known.
    var sector: String?
    /// Mail domains this company is known by, set on the company row. A company
    /// can have several (a rebrand, a regional domain, an acquired team's), and
    /// the list grows on its own as contacts are added — see
    /// `JobStore.addContact`. Empty until the `domains` migration has run.
    var domains: [String] = []
    var contacts: [Contact] = []

    enum CodingKeys: String, CodingKey {
        case id
        case company = "name"
        case sector
        case domains
        case contacts = "recruiters"
    }

    init(id: String, company: String, sector: String? = nil, domains: [String] = [], contacts: [Contact] = []) {
        self.id = id
        self.company = company
        self.sector = sector
        self.domains = domains
        self.contacts = contacts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        company = try c.decode(String.self, forKey: .company)
        sector = try c.decodeIfPresent(String.self, forKey: .sector)
        domains = (try c.decodeIfPresent([String].self, forKey: .domains) ?? []).compactMap(MailDomain.clean)
        contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
    }

    /// Work domains seen on this company's contacts' addresses, most common first.
    var contactDomains: [String] {
        var counts: [String: Int] = [:]
        for contact in contacts {
            if let domain = MailDomain.work(fromEmail: contact.email) { counts[domain, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// Every domain this company answers to: the ones set on the row, then any
    /// its contacts use that aren't listed yet.
    var allDomains: [String] {
        domains + contactDomains.filter { !domains.contains($0) }
    }

    /// The company's main mail domain (e.g. "stripe.com"), or "" when unknown.
    var mailDomain: String { allDomains.first ?? "" }

    /// The contacts still worth sending, and the ones marked invalid. The company
    /// screen shows them as two groups and only ever mails the first.
    var validContacts: [Contact] { contacts.filter(\.isValid) }
    var invalidContacts: [Contact] { contacts.filter { !$0.isValid } }

    /// Contacts at this company who wrote back, and the ones still silent after
    /// being mailed. Neither counts anyone never mailed.
    var repliedContacts: [Contact] { contacts.filter(\.hasReplied) }
    var awaitingContacts: [Contact] { contacts.filter { $0.isSent && !$0.hasReplied } }

    /// Days since the most recent mail to anyone here who hasn't answered — nil
    /// when nobody is waiting on a reply.
    var quietDays: Int? {
        guard let last = awaitingContacts.compactMap(\.sentAt).max() else { return nil }
        return Calendar.current.dateComponents([.day], from: last, to: .now).day
    }

    /// Whether this company answers a search box. Matching runs over the people
    /// inside as well as the company itself, so a half-remembered contact's name
    /// finds the company you'd have to have remembered to find them — the same
    /// predicate on Home and in the catalog, so a query that works on one screen
    /// works on the other.
    ///
    /// `query` is expected to be already trimmed; an empty one matches nothing,
    /// because "no query" is a decision for the caller, not for a filter.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return false }
        if company.localizedCaseInsensitiveContains(query) { return true }
        if sector?.localizedCaseInsensitiveContains(query) == true { return true }
        if domains.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        return contacts.contains { $0.matches(query) }
    }
}

extension Array where Element == Contact {
    /// Alphabetical by what each contact is called on screen.
    func sortedByName() -> [Contact] {
        sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

extension Array where Element == Job {
    /// Alphabetical by company name, the order every company list shows.
    func sortedByName() -> [Job] {
        sorted { $0.company.localizedCaseInsensitiveCompare($1.company) == .orderedAscending }
    }

    /// The companies from any of `sources` that match `query`, each once, by
    /// name — how a search over loaded pages and server hits is shown.
    static func matching(_ query: String, in sources: [Job]...) -> [Job] {
        var seen = Set<String>()
        return sources.joined()
            .filter { $0.matches(query) && seen.insert($0.id).inserted }
            .sortedByName()
    }
}

/// Mail-domain rules shared by the company form, the contact form and the
/// store, so "is this the same company?" is answered the same way everywhere.
enum MailDomain {
    /// Reduce whatever was typed or pasted — a URL, "@stripe.com", someone's
    /// address — to a bare, lowercased domain. Nil when what's left isn't one.
    nonisolated static func clean(_ raw: String) -> String? {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where d.hasPrefix(scheme) { d.removeFirst(scheme.count) }
        if let cut = d.firstIndex(where: { "/?#".contains($0) }) { d = String(d[..<cut]) }
        if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        while d.hasSuffix(".") { d.removeLast() }
        return isWellFormed(d) ? d : nil
    }

    /// The company domain of an address, or nil for a personal mailbox (a Gmail
    /// address says nothing about where someone works) or a malformed one.
    nonisolated static func work(fromEmail email: String) -> String? {
        guard email.contains("@"), let domain = clean(email), !isPersonal(domain) else { return nil }
        return domain
    }

    nonisolated static func isPersonal(_ domain: String) -> Bool {
        personalDomains.contains(domain)
    }

    /// Whether `email` has the shape of a deliverable address: one `@`, a
    /// mailbox with no spaces before it and a well-formed domain after. What the
    /// contact forms require before a row can be saved to the shared catalog —
    /// `jane@` or `jane@acme` would only ever bounce.
    nonisolated static func isPlausibleAddress(_ email: String) -> Bool {
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              !parts[0].contains(where: \.isWhitespace) else { return false }
        return isWellFormed(parts[1].lowercased())
    }

    /// Letters, digits, dots and hyphens, with at least one dot and no empty
    /// labels. Also what keeps a domain safe to put inside a PostgREST filter.
    nonisolated static func isWellFormed(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return domain.count <= 253 && labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    nonisolated private static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.in", "ymail.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com",
        "mac.com", "aol.com", "proton.me", "protonmail.com", "rediffmail.com",
        "zoho.com", "gmx.com", "mail.com", "yandex.com"
    ]
}
