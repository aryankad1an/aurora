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
    /// The vault that owns this contact: the user's own, or one imported with
    /// its code. Only the owner can edit, delete or share a contact; anyone who
    /// can read it can mail it and mark it invalid. Nil for an unsaved draft.
    var vaultID: String?
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
        case vaultID = "vault_id"
        case keyID = "key_id"
        case sealed
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

    /// Whether there's a name to greet them by. When there isn't, mail opens
    /// "Hi," and the app says "Name not detected" wherever the contact shows.
    var isNameDetected: Bool { !greeting.isEmpty }

    /// Whether this contact has nothing better than its address to be greeted
    /// by, and so is worth looking up in the account's mail.
    var needsNameLookup: Bool {
        RecipientName.needsLookup(name: name, email: email, greetingName: greetingName, replyFrom: replyFrom)
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

    /// Whether it's the user's own: theirs to edit, delete and share. A draft
    /// not saved yet is.
    var isOwned: Bool { vaultID == nil || KeyRing.shared.owns(vault: vaultID) }

    /// Whether it can be deleted here: the user's own, and never mailed (a sent
    /// mail is a permanent record).
    var isDeletable: Bool { isOwned && !isSent }

    /// The private fields, as they're sealed into the row.
    var sealedFields: KeyRing.ContactFields {
        func value(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
        return KeyRing.ContactFields(name: value(name), email: value(email), position: value(position),
                                     phone: value(phone), greetingName: value(greetingName))
    }

    /// What they said, without the quoted mail Gmail's snippet runs on into.
    /// Nil when no preview was captured.
    var replyPreview: String? {
        guard let snippet = replySnippet?.withoutQuoteHeader, !snippet.isEmpty else { return nil }
        return snippet
    }

    /// Rows carry nulls for optional columns, so decode leniently and default.
    ///
    /// A row from a vault this account can't read throws, and the lists that
    /// hold contacts skip it (see `LossyContacts`): another user's contacts
    /// never reach the screen. A readable row's fields come out of its seal; one
    /// the owner hasn't sealed yet (the first sign-in after the migration) is
    /// read from its plain columns.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vaultID = try c.decodeIfPresent(String.self, forKey: .vaultID)
        guard let vaultID, KeyRing.shared.canRead(vault: vaultID) else { throw KeyRing.Locked.notReadable }
        // Rows written before the column existed come back null — those are valid.
        isValid = try c.decodeIfPresent(Bool.self, forKey: .isValid) ?? true
        if let sealed = try c.decodeIfPresent(String.self, forKey: .sealed) {
            let keyID = try c.decode(String.self, forKey: .keyID)
            let fields = try KeyRing.shared.openContact(sealed, id: id, vaultID: vaultID, keyID: keyID)
            email = fields.email ?? ""
            name = fields.name ?? ""
            phone = fields.phone
            position = fields.position ?? ""
            greetingName = fields.greetingName
        } else {
            email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            phone = try c.decodeIfPresent(String.self, forKey: .phone)
            position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
            greetingName = try c.decodeIfPresent(String.self, forKey: .greetingName)
        }
    }
}

/// A list of contact rows with the ones this account can't open left out — a
/// company's contacts are every user's, and only the readable ones are kept.
struct LossyContacts: Decodable {
    let contacts: [Contact]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [Contact] = []
        while !container.isAtEnd {
            if let contact = try? container.decode(Contact.self) {
                kept.append(contact)
            } else {
                // Step past the row that didn't open.
                _ = try? container.decode(Skipped.self)
            }
        }
        contacts = kept
    }

    private struct Skipped: Decodable {}
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
    var contact: Contact
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
    /// Other names the company goes by — its brands, a former name, the name
    /// it trades under (Eternal: Zomato, Blinkit, District). Shown under its
    /// name and searched like it. Empty until the also-known-as migration has run.
    var alsoKnownAs: [String] = []
    var contacts: [Contact] = []

    // MARK: Links and fresher hiring
    //
    // Filled from the Fresher Hiring Ledger and the company's own website (see
    // scripts/fresher_ledger), and editable in Edit Company. All empty until the
    // fresher-hiring migration in the README has run.

    /// The company's own website, e.g. "https://stripe.com".
    var website: String?
    /// How the website was found ("wikidata", "mail_domain", "edited", …).
    var websiteSource: String?
    var careersURL: String?
    var careersSource: String?
    /// A square PNG the company's own site offers as its icon. Shown in place of
    /// the monogram wherever the company appears.
    var logoURL: String?
    /// Whether the company is known to hire freshers — every company in the
    /// ledger is. What the Companies filter's Freshers scope shows.
    var isFresher = false
    /// The Fresher Hiring Ledger companies this one is (one, or a few when
    /// subsidiaries share its mail domain).
    var ledgerIDs: [String] = []
    /// Product / MNC, IT services / consulting, …
    var companyType: String?
    /// Every route it has been seen hiring freshers by, as stored.
    var hiringRouteValues: [String] = []
    /// Whether a fresher posting is open right now.
    var isOpenNow = false
    /// The months its off-campus hiring usually opens, e.g. "Sep, Dec".
    var usuallyOpens: String?
    /// Graduation years its fresher roles have asked for.
    var batches: [String] = []
    /// The fresher roles it hires for most.
    var fresherRoles: [String] = []

    enum CodingKeys: String, CodingKey {
        case id
        case company = "name"
        case sector
        case domains
        case alsoKnownAs = "also_known_as"
        case contacts = "recruiters"
        case website
        case websiteSource = "website_source"
        case careersURL = "careers_url"
        case careersSource = "careers_source"
        case logoURL = "logo_url"
        case isFresher = "is_fresher"
        case ledgerIDs = "ledger_ids"
        case companyType = "company_type"
        case hiringRouteValues = "hiring_routes"
        case isOpenNow = "open_now"
        case usuallyOpens = "usually_opens"
        case batches
        case fresherRoles = "fresher_roles"
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
        alsoKnownAs = try c.decodeIfPresent([String].self, forKey: .alsoKnownAs) ?? []
        contacts = try c.decodeIfPresent(LossyContacts.self, forKey: .contacts)?.contacts ?? []
        // Every one of these is absent until the fresher-hiring migration has run.
        website = try c.decodeIfPresent(String.self, forKey: .website)
        websiteSource = try c.decodeIfPresent(String.self, forKey: .websiteSource)
        careersURL = try c.decodeIfPresent(String.self, forKey: .careersURL)
        careersSource = try c.decodeIfPresent(String.self, forKey: .careersSource)
        logoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
        isFresher = try c.decodeIfPresent(Bool.self, forKey: .isFresher) ?? false
        ledgerIDs = try c.decodeIfPresent([String].self, forKey: .ledgerIDs) ?? []
        companyType = try c.decodeIfPresent(String.self, forKey: .companyType)
        hiringRouteValues = try c.decodeIfPresent([String].self, forKey: .hiringRouteValues) ?? []
        isOpenNow = try c.decodeIfPresent(Bool.self, forKey: .isOpenNow) ?? false
        usuallyOpens = try c.decodeIfPresent(String.self, forKey: .usuallyOpens)
        batches = try c.decodeIfPresent([String].self, forKey: .batches) ?? []
        fresherRoles = try c.decodeIfPresent([String].self, forKey: .fresherRoles) ?? []
    }

    /// The hiring routes it's known by, strongest first. A value the app doesn't
    /// know is left out rather than shown raw.
    var hiringRoutes: [HiringRoute] {
        let known = Set(hiringRouteValues.compactMap(HiringRoute.init(rawValue:)))
        return HiringRoute.ordered.filter(known.contains)
    }

    /// The bucket its strongest route puts it in.
    var routeCategory: RouteCategory? { RouteCategory.of(hiringRoutes) }

    var websiteLink: URL? { CompanyLink.url(website) }
    var careersLink: URL? { CompanyLink.url(careersURL) }
    /// Only ever an https image: an http one would be blocked by App Transport
    /// Security, and every logo on file is https.
    var logoLink: URL? {
        guard let url = CompanyLink.url(logoURL), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Show `details` on this company at once, as Edit Company saved them. What the
    /// server works out for itself (where a link came from) arrives with the
    /// refetch that follows.
    mutating func apply(_ details: CompanyDetails) {
        func optional(_ text: String) -> String? { text.isEmpty ? nil : text }
        company = details.name
        sector = optional(details.sector)
        alsoKnownAs = details.alsoKnownAs
        domains = details.domains
        website = optional(details.website)
        careersURL = optional(details.careersURL)
        logoURL = optional(details.logoURL)
        isFresher = details.isFresher
        isOpenNow = details.isOpenNow
        companyType = optional(details.companyType)
        hiringRouteValues = details.orderedRoutes.map(\.rawValue)
        usuallyOpens = optional(details.usuallyOpens)
        batches = details.batches
        fresherRoles = details.fresherRoles
    }

    /// Everything Edit Company can change, as it stands.
    var details: CompanyDetails {
        CompanyDetails(
            name: company, sector: sector ?? "", alsoKnownAs: alsoKnownAs, domains: domains,
            website: website ?? "", careersURL: careersURL ?? "", logoURL: logoURL ?? "",
            isFresher: isFresher, isOpenNow: isOpenNow, companyType: companyType ?? "",
            hiringRoutes: Set(hiringRoutes), usuallyOpens: usuallyOpens ?? "",
            batches: batches, fresherRoles: fresherRoles
        )
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

    /// Contacts at this company who wrote back.
    var repliedContacts: [Contact] { contacts.filter(\.hasReplied) }

    /// Valid contacts already mailed, and the valid ones not mailed yet. An
    /// invalid contact counts as neither: a mail that bounced reached nobody,
    /// and a dead address is never going to be contacted.
    var contactedContacts: [Contact] { validContacts.filter(\.isSent) }
    var uncontactedContacts: [Contact] { validContacts.filter { !$0.isSent } }

    /// When the latest mail to a valid contact went out — nil when none has.
    /// Mail to contacts since marked invalid doesn't count, so a company whose
    /// every mail bounced doesn't read as one you've been waiting on for weeks.
    var lastSentAt: Date? { contactedContacts.compactMap(\.sentAt).max() }

    /// Whether this company answers a search box. Matching runs over the people
    /// inside as well as the company itself, so a half-remembered contact's name
    /// finds the company you'd have to have remembered to find them — the same
    /// predicate on Home and in the catalog, so a query that works on one screen
    /// works on the other.
    ///
    /// `query` is expected to be already trimmed; an empty one matches nothing,
    /// because "no query" is a decision for the caller, not for a filter.
    /// The other name `query` found this company by, when its own name
    /// doesn't match — what a search result shows so "Blinkit" turning up
    /// Eternal isn't a puzzle.
    func otherName(matching query: String) -> String? {
        guard !query.isEmpty, !company.localizedCaseInsensitiveContains(query) else { return nil }
        return alsoKnownAs.first { $0.localizedCaseInsensitiveContains(query) }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return false }
        if company.localizedCaseInsensitiveContains(query) { return true }
        if alsoKnownAs.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if sector?.localizedCaseInsensitiveContains(query) == true { return true }
        if companyType?.localizedCaseInsensitiveContains(query) == true { return true }
        if fresherRoles.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if domains.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        return contacts.contains { $0.matches(query) }
    }
}

/// A company's editable fields, as Edit Company holds them while they're
/// changed: text fields as typed, so an empty field means "none".
struct CompanyDetails: Equatable {
    var name = ""
    var sector = ""
    var alsoKnownAs: [String] = []
    var domains: [String] = []
    var website = ""
    var careersURL = ""
    var logoURL = ""
    var isFresher = false
    var isOpenNow = false
    var companyType = ""
    var hiringRoutes: Set<HiringRoute> = []
    var usuallyOpens = ""
    var batches: [String] = []
    var fresherRoles: [String] = []

    /// The routes in their stored order, strongest first.
    var orderedRoutes: [HiringRoute] { HiringRoute.ordered.filter(hiringRoutes.contains) }

    /// The fresher details with surrounding space trimmed and empty entries
    /// dropped — what's compared and saved.
    var trimmed: CompanyDetails {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func list(_ xs: [String]) -> [String] {
            var seen = Set<String>()
            return xs.map(clean).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        var d = self
        d.name = clean(name)
        d.sector = clean(sector)
        // A name it goes by is never the name itself.
        d.alsoKnownAs = list(alsoKnownAs).filter { $0.caseInsensitiveCompare(d.name) != .orderedSame }
        d.website = clean(website)
        d.careersURL = clean(careersURL)
        d.logoURL = clean(logoURL)
        d.companyType = clean(companyType)
        d.usuallyOpens = clean(usuallyOpens)
        d.batches = list(batches)
        d.fresherRoles = list(fresherRoles)
        return d
    }

    /// Whether any of the fields only the fresher-hiring migration can store
    /// is set.
    var hasFresherDetails: Bool {
        let t = trimmed
        return !t.website.isEmpty || !t.careersURL.isEmpty || !t.logoURL.isEmpty || t.isFresher
            || !t.companyType.isEmpty || !t.hiringRoutes.isEmpty || !t.usuallyOpens.isEmpty
            || !t.batches.isEmpty || !t.fresherRoles.isEmpty
    }

    /// A link field that holds something that isn't a web address. Saving is
    /// held back until it's fixed or cleared, rather than storing a dead link.
    var invalidLinkFields: [String] {
        var bad: [String] = []
        let t = trimmed
        if !t.website.isEmpty && CompanyLink.url(t.website) == nil { bad.append("Website") }
        if !t.careersURL.isEmpty && CompanyLink.url(t.careersURL) == nil { bad.append("Careers page") }
        if !t.logoURL.isEmpty && CompanyLink.url(t.logoURL)?.scheme?.lowercased() != "https" { bad.append("Logo") }
        return bad
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
