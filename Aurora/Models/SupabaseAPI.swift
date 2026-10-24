import Foundation

/// Talks to Supabase's auto-generated REST API (PostgREST). Companies are a
/// shared catalog. Contacts belong to vaults and are sealed (see `Sealing`):
/// every request that brings contacts back asks only for the vaults this
/// account can read (`readableContacts`), and each row is opened on the phone.
/// Each user's Home selection (`tracked_companies`), sent records
/// (`mail_sends`), profile and templates are rows keyed by their Gmail
/// address, with their private parts sealed under the account key.
enum SupabaseAPI {
    // MARK: - Catalog (every company, with contacts)

    /// How many companies one page of the catalog holds.
    nonisolated static let defaultPageSize = 50

    /// Every company in the shared catalog, each with its contacts and sector.
    /// A left join, so companies with no contacts are included too — the
    /// Companies list decides whether to show them. Sorted by name.
    ///
    /// The contact columns are selected with `*` rather than by name for the
    /// same reason `fetchSends` does it: naming a column PostgREST doesn't have
    /// yet fails the whole request, and `greeting_name` only exists once the
    /// migration in the README has been run.
    ///
    /// `scope` narrows it to fresher-hiring companies (see `CatalogScope`).
    static func fetchAllCompanies(limit: Int = defaultPageSize, offset: Int = 0,
                                  scope: CatalogScope = .all) async throws -> [Job] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
            readableContacts(),
            URLQueryItem(name: "order", value: "name")
        ] + scope.filters
        if limit > 0 {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
            queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        let request = makeRequest(path: "companies", query: queryItems)
        let data = try await send(request)
        // `select=*` returns whatever columns exist, so whether `domains` is
        // among them says whether its migration has run — known from the first
        // load rather than discovered by a failed save.
        if let probe = try? decoder.decode([ColumnProbe].self, from: data).first {
            domainsColumnMissing = !probe.hasDomains
            fresherColumnsMissing = !probe.hasFresher
            alsoKnownAsColumnMissing = !probe.hasAlsoKnownAs
        }
        return try decoder.decode([Job].self, from: data)
    }

    private struct ColumnProbe: Decodable {
        let hasDomains: Bool
        let hasFresher: Bool
        let hasAlsoKnownAs: Bool
        private enum Key: String, CodingKey { case domains, is_fresher, also_known_as }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            hasDomains = c.contains(.domains)
            hasFresher = c.contains(.is_fresher)
            hasAlsoKnownAs = c.contains(.also_known_as)
        }
    }

    /// How many catalog companies are in `scope` — the figure on its filter
    /// chip. Counted by the server (a one-row request asking for the total), so
    /// it's right before any page of that scope has loaded.
    static func countCompanies(scope: CatalogScope) async throws -> Int {
        try await count("companies", scope.filters)
    }

    /// How many rows of `path` match `filters`, counted by the server. `column`
    /// is any column the table has — `profiles` has no `id`.
    static func count(_ path: String, _ filters: [URLQueryItem], column: String = "id") async throws -> Int {
        var request = makeRequest(path: path, query: [URLQueryItem(name: "select", value: column)] + filters)
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")
        request.setValue("0-0", forHTTPHeaderField: "Range")
        request.setValue("items", forHTTPHeaderField: "Range-Unit")
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else { throw error(status: http.statusCode, body: data, request: request) }
        // "0-0/1162", or "*/0" when there are none.
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int($0) }) else {
            throw SupabaseError.badResponse
        }
        return total
    }

    /// Search the shared catalog for companies matching a query string across company name,
    /// sector, domain and other names. Contacts are sealed, so the server can't
    /// search them: `contactCompanyIDs` are the companies of the contacts that
    /// matched on the phone (`JobStore.contactCompanies(matching:)`), fetched here
    /// alongside.
    static func searchCompanies(query: String, contactCompanyIDs: Set<String> = [],
                                limit: Int = defaultPageSize) async throws -> [Job] {
        // Characters that carry meaning in a PostgREST `or=(…)` filter would change
        // the shape of the filter rather than the value searched for.
        let reserved = CharacterSet(charactersIn: ",()*\"\\%")
        let cleaned = query.components(separatedBy: reserved).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return [] }
        let pattern = "*\(cleaned)*"

        // 1. Companies by name or sector — and by domain, when the query is one.
        // 2. Companies by another name they go by. Both in flight at once.
        // Several words also match one by one, in any order, as the phone's
        // own search does: "cloud juniper" finds Juniper Cloud.
        let words = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        async let byCompany = searchCompanyRows(pattern: pattern, words: words.count > 1 ? words : [],
                                                domain: MailDomain.clean(cleaned), limit: limit)
        async let byOtherName = companiesKnownAs(cleaned, limit: limit)
        var foundCompanies = try await byCompany
        let knownAs = await byOtherName
        foundCompanies += knownAs.filter { found in !foundCompanies.contains { $0.id == found.id } }
        // 3. Companies that employ a matching contact, matched on the phone.
        let employers = Array(contactCompanyIDs.subtracting(foundCompanies.map(\.id)).sorted().prefix(limit))
        foundCompanies += try await fetchCompanies(ids: Set(employers))
        return foundCompanies.sortedByName()
    }

    /// Companies that go by another name matching `query` — "Blinkit" finds
    /// Eternal. A database function does the matching, since PostgREST can't
    /// filter part of an array element. Empty, not an error, until the
    /// also-known-as migration has run: the rest of the search still answers.
    private static func companiesKnownAs(_ query: String, limit: Int) async -> [Job] {
        guard !alsoKnownAsColumnMissing else { return [] }
        let request = makeRequest(path: "rpc/companies_known_as", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
            readableContacts(),
            URLQueryItem(name: "limit", value: String(limit))
        ])
        return (try? decoder.decode([Job].self, from: try await send(request))) ?? []
    }

    /// Companies whose name or sector matches `pattern`, or that list `domain`.
    /// The domains column only exists once its migration has run; without it
    /// the filter is rejected, so this retries without it rather than failing
    /// the whole search.
    private static func searchCompanyRows(pattern: String, words: [String] = [], domain: String?,
                                          limit: Int) async throws -> [Job] {
        func request(includingDomains: Bool) -> URLRequest {
            var filters = ["name.ilike.\(pattern)", "sector.ilike.\(pattern)"]
            for column in ["name", "sector"] where !words.isEmpty {
                filters.append("and(" + words.map { "\(column).ilike.*\($0)*" }.joined(separator: ",") + ")")
            }
            if includingDomains, let domain { filters.append("domains.cs.{\(domain)}") }
            return makeRequest(path: "companies", query: [
                URLQueryItem(name: "select", value: "*,recruiters(*)"),
                readableContacts(),
                URLQueryItem(name: "or", value: "(" + filters.joined(separator: ",") + ")"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "order", value: "name")
            ])
        }
        do {
            return try decoder.decode([Job].self, from: try await send(request(includingDomains: !domainsColumnMissing)))
        } catch SupabaseError.schemaOutOfDate where !domainsColumnMissing {
            domainsColumnMissing = true
            return try decoder.decode([Job].self, from: try await send(request(includingDomains: false)))
        }
    }

    /// Every company that `domain` belongs to: the ones listing it on their row,
    /// and the ones with a contact at that domain (`contactCompanyIDs`, found on
    /// the phone, since addresses are sealed). Used to point a new contact at
    /// the company it most likely belongs to, so the same company never gets
    /// entered twice under two names.
    static func companies(forDomain domain: String, contactCompanyIDs: Set<String> = []) async throws -> [Job] {
        guard MailDomain.isWellFormed(domain) else { return [] }
        var found = try await companiesListing(domain)
        found += try await fetchCompanies(ids: contactCompanyIDs.subtracting(found.map(\.id)))
        return found
    }

    /// The companies with `domain` on their row, or whose website is on it — a
    /// fresher-hiring company added from the ledger has a website but no
    /// contacts yet, and the first contact added there should find it. Empty
    /// until the domains migration has run.
    private static func companiesListing(_ domain: String) async throws -> [Job] {
        guard !domainsColumnMissing else { return [] }
        func request(includingWebsite: Bool) -> URLRequest {
            var filters = ["domains.cs.{\(domain)}"]
            if includingWebsite {
                // The site's host is the domain or one under it, with or
                // without a path after it.
                for host in ["//\(domain)", "//www.\(domain)", ".\(domain)"] {
                    filters += ["website.ilike.*\(host)", "website.ilike.*\(host)/*"]
                }
            }
            return makeRequest(path: "companies", query: [
                URLQueryItem(name: "select", value: "*,recruiters(*)"),
                readableContacts(),
                URLQueryItem(name: "or", value: "(" + filters.joined(separator: ",") + ")")
            ])
        }
        do {
            return try decoder.decode([Job].self, from: try await send(request(includingWebsite: !fresherColumnsMissing)))
        } catch SupabaseError.schemaOutOfDate where !fresherColumnsMissing {
            fresherColumnsMissing = true
            return try await companiesListing(domain)
        } catch SupabaseError.schemaOutOfDate {
            domainsColumnMissing = true
            return []
        }
    }

    /// Companies by id, with their contacts. One request; none when `ids` is empty.
    static func companies(ids: Set<String>) async throws -> [Job] {
        try await fetchCompanies(ids: ids)
    }

    private static func fetchCompanies(ids: Set<String>) async throws -> [Job] {
        guard !ids.isEmpty else { return [] }
        let request = makeRequest(path: "companies", query: [
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
            readableContacts(),
            URLQueryItem(name: "id", value: "in.(\(ids.sorted().joined(separator: ",")))")
        ])
        return try decoder.decode([Job].self, from: try await send(request))
    }

    /// Fetch a single company by id from Supabase with all contacts and sector.
    static func fetchCompany(id: String) async throws -> Job? {
        let request = makeRequest(path: "companies", query: [
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
            readableContacts(),
            URLQueryItem(name: "id", value: "eq.\(id)")
        ])
        let data = try await send(request)
        return try decoder.decode([Job].self, from: data).first
    }

    // MARK: - Home selection (tracked companies, per user)

    /// This user's tracked companies (with contacts), resolved in one request:
    /// PostgREST embeds the `companies` row (and its `contacts`) for each
    /// `tracked_companies` membership row, so the whole Home payload comes back in
    /// a single round trip. Sorted by name here since the join order isn't stable.
    static func fetchTrackedCompanies(userEmail: String) async throws -> [Job] {
        let request = makeRequest(path: "tracked_companies", query: [
            URLQueryItem(name: "select", value: "companies(*,recruiters(*))"),
            readableContacts(under: "companies.recruiters"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)")
        ])
        let data = try await send(request)
        // Each row wraps the embedded company; a company deleted out from under a
        // membership row (before the FK cascade fires) comes back null — skip it.
        struct Row: Decodable { let companies: Job? }
        return try decoder.decode([Row].self, from: data)
            .compactMap(\.companies)
            .sortedByName()
    }

    /// Just the tracked company ids for this user. Used once per account to lift a
    /// pre-sync, on-device selection up to the server (see `JobStore`).
    static func fetchTrackedIDs(userEmail: String) async throws -> [String] {
        let request = makeRequest(path: "tracked_companies", query: [
            URLQueryItem(name: "select", value: "company_id"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)")
        ])
        let data = try await send(request)
        struct Row: Decodable { let company_id: String }
        return try decoder.decode([Row].self, from: data).map(\.company_id)
    }

    /// Track a company on this user's Home. Idempotent: upserts on the composite
    /// primary key so re-adding an already-tracked company is a no-op.
    static func addTracked(userEmail: String, companyID: String) async throws {
        let body: [String: Any] = ["user_email": userEmail, "company_id": companyID]
        try await write(method: "POST", path: "tracked_companies", body: body,
                        prefer: "return=minimal,resolution=merge-duplicates",
                        onConflict: "user_email,company_id")
    }

    /// Untrack a company from this user's Home.
    static func removeTracked(userEmail: String, companyID: String) async throws {
        try await write(method: "DELETE", path: "tracked_companies", query: [
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "company_id", value: "eq.\(companyID)")
        ])
    }

    /// Every send this user has made, newest first. One row per send, so the
    /// same contact can appear multiple times (the send history).
    ///
    /// Selects `*` rather than a column list on purpose: the reply-tracking
    /// columns only exist once the migration in the README has been run, and
    /// naming a column PostgREST doesn't have fails the whole request. With `*`
    /// the app runs either way and simply has no reply data until then.
    ///
    /// `limit: 0` is the whole history. The server answers no more than a thousand
    /// rows to one request however many are asked for — the app used to take that
    /// thousand for everything, so on an account with more, every older send was
    /// missing: its contact looked unmailed, and could be mailed again. It now
    /// reads a thousand at a time until a short page says that's all of them.
    static func fetchSends(userEmail: String, limit: Int = defaultPageSize, offset: Int = 0) async throws -> [MailSend] {
        if limit == 0 {
            let page = 1000
            var all: [MailSend] = []
            var seen = Set<String>()
            var offset = 0
            while true {
                let batch = try await fetchSends(userEmail: userEmail, limit: page, offset: offset)
                offset += batch.count
                // A mail recorded mid-read lands at the top and pushes every row down
                // one, so the next page starts with a row already read.
                all += batch.filter { seen.insert($0.id).inserted }
                if batch.count < page { return all }
            }
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            // `id` breaks ties, so a send isn't read twice or skipped between pages.
            URLQueryItem(name: "order", value: "sent_at.desc,id.asc")
        ]
        if limit > 0 {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
            queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        let request = makeRequest(path: "mail_sends", query: queryItems)
        let data = try await send(request)
        return try decoder.decode([MailSend].self, from: data)
    }

    /// The full send history for one contact, newest first.
    static func fetchSendHistory(userEmail: String, contactID: String) async throws -> [MailSend] {
        let request = makeRequest(path: "mail_sends", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "recruiter_id", value: "eq.\(contactID)"),
            URLQueryItem(name: "order", value: "sent_at.desc")
        ])
        let data = try await send(request)
        return try decoder.decode([MailSend].self, from: data)
    }

    /// Build the Activity feed from the user's send history — one entry per
    /// send, so re-sending the same contact shows up as a separate row. Each
    /// contact's name/position and company are resolved (even for companies the
    /// user no longer tracks, so history survives a Home removal). `sends` is the
    /// raw list from `fetchSends`, newest first.
    ///
    /// `held` are contacts the app already has in memory, by id: they're used as
    /// they are and only the rest are fetched. Nearly everyone mailed is on a
    /// tracked company, so this is a request or two, not one per fifty people.
    static func fetchActivity(sends: [MailSend], held: [String: HeldContact] = [:]) async throws -> [ActivityEntry] {
        guard !sends.isEmpty else { return [] }
        let allIDs = Array(Set(sends.map(\.contactID))).filter { held[$0] == nil }

        // The contact (opened from its seal) and the name of its company. A
        // contact this account can no longer read leaves its sends out of the
        // feed.
        struct Row: Decodable {
            let contact: Contact
            let companyName: String?
            private enum Key: String, CodingKey { case companies }
            private struct Company: Decodable { let name: String }
            init(from decoder: Decoder) throws {
                contact = try Contact(from: decoder)
                companyName = try decoder.container(keyedBy: Key.self)
                    .decodeIfPresent(Company.self, forKey: .companies)?.name
            }
        }
        struct Rows: Decodable {
            let rows: [Row]
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var kept: [Row] = []
                while !container.isAtEnd {
                    if let row = try? container.decode(Row.self) { kept.append(row) } else { _ = try? container.decode(Skipped.self) }
                }
                rows = kept
            }
        }

        // 50 ids per request (a longer `in.(…)` list overflows the URL), all
        // chunks at once rather than one after another.
        let requests = stride(from: 0, to: allIDs.count, by: defaultPageSize).map { start in
            makeRequest(path: "recruiters", query: [
                URLQueryItem(name: "select", value: "*,companies(name)"),
                readableContacts(under: nil),
                URLQueryItem(name: "id", value: "in.(\(allIDs[start..<min(start + defaultPageSize, allIDs.count)].joined(separator: ",")))")
            ])
        }
        let pages = try await withThrowingTaskGroup(of: Data.self) { group in
            for request in requests { group.addTask { try await send(request) } }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        var byID = held
        for page in pages {
            for row in try decoder.decode(Rows.self, from: page).rows {
                let c = row.contact
                byID[c.id] = HeldContact(c, company: row.companyName ?? "")
            }
        }

        // One entry per send, keyed by the send's own id (unique per send).
        return sends.compactMap { send -> ActivityEntry? in
            guard let info = byID[send.contactID] else { return nil }
            var contact = Contact(id: send.contactID, email: info.email, name: info.name, phone: info.phone,
                                  position: info.position, greetingName: info.greetingName,
                                  linkedIn: info.linkedIn, location: info.location, isValid: info.isValid,
                                  isSent: true, sentAt: send.sentAt,
                                  sentSubject: send.subject, sentBody: send.body,
                                  repliedAt: send.repliedAt, replyFrom: send.replyFrom,
                                  replySnippet: send.replySnippet)
            contact.vaultID = info.vaultID
            return ActivityEntry(id: send.id, company: info.company, contact: contact)
        }
    }

    /// What the Activity feed needs of a contact, and of the company they're at.
    /// Every detail, not just what the feed shows: a contact opened from
    /// Activity is edited and saved whole, and a field missing here would be
    /// saved as cleared.
    struct HeldContact: Sendable {
        let name: String
        let email: String
        let phone: String?
        let position: String
        let greetingName: String?
        let linkedIn: String?
        let location: String?
        let isValid: Bool
        var vaultID: String?
        let company: String

        init(_ contact: Contact, company: String) {
            name = contact.name
            email = contact.email
            phone = contact.phone
            position = contact.position
            greetingName = contact.greetingName
            linkedIn = contact.linkedIn
            location = contact.location
            isValid = contact.isValid
            vaultID = contact.vaultID
            self.company = company
        }
    }

    /// A row that didn't open, stepped past.
    private struct Skipped: Decodable {}

    // MARK: - Company catalog writes

    /// Set once the database reports it has no `companies.domains` column — the
    /// migration in the README hasn't run. Domains can't be stored until it has,
    /// so the store tells the user rather than dropping them silently.
    private(set) static var domainsColumnMissing = false

    /// Set once the database reports it has none of the fresher-hiring columns
    /// (website, careers page, logo, routes…): their migration hasn't run. The
    /// rest of a company still saves; the store says what didn't.
    private(set) static var fresherColumnsMissing = false

    /// Set once the database reports it has no `also_known_as` column: its
    /// migration hasn't run. A company's other names can't be stored or
    /// searched until it has.
    private(set) static var alsoKnownAsColumnMissing = false

    /// Create a company in the catalog and return its new id. The company is
    /// created even when its domains or fresher details can't be stored (see
    /// `domainsColumnMissing`, `fresherColumnsMissing`).
    static func addCompany(name: String, sector: String?, domains: [String] = []) async throws -> String {
        var details = CompanyDetails()
        details.name = name
        details.sector = sector ?? ""
        details.domains = domains
        return try await addCompany(details)
    }

    static func addCompany(_ details: CompanyDetails) async throws -> String {
        var body = companyBody(details.trimmed, previous: nil)
        if details.domains.isEmpty { body.removeValue(forKey: "domains") }
        while true {
            do {
                return try await insertReturningID(path: "companies", body: stripMissingColumns(body))
            } catch SupabaseError.schemaOutOfDate where noteMissingColumn(in: body) {
                continue
            }
        }
    }

    /// Save a catalog company's details. `previous` is the company as it was,
    /// so a website or careers link changed here is marked as edited by hand —
    /// a later import from the ledger leaves it alone.
    static func updateCompany(id: String, details: CompanyDetails, previous: Job?) async throws {
        let body = companyBody(details.trimmed, previous: previous)
        let query = [URLQueryItem(name: "id", value: "eq.\(id)")]
        while true {
            do {
                try await write(method: "PATCH", path: "companies", query: query, body: stripMissingColumns(body))
                return
            } catch SupabaseError.schemaOutOfDate where noteMissingColumn(in: body) {
                continue
            }
        }
    }

    /// Put back where a company's links came from — an undo restores a link
    /// to what it was, and it was not edited by hand.
    static func restoreLinkSources(id: String, website: String?, careers: String?) async throws {
        guard !fresherColumnsMissing else { return }
        try await write(method: "PATCH", path: "companies",
                        query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                        body: ["website_source": website ?? NSNull(), "careers_source": careers ?? NSNull()])
    }

    /// The columns only the fresher-hiring migration adds.
    private static let fresherColumns: Set<String> = [
        "website", "website_source", "careers_url", "careers_source", "logo_url", "is_fresher",
        "company_type", "route_category", "hiring_routes", "open_now", "usually_opens", "batches",
        "fresher_roles"
    ]

    /// A company row's body from its details. Empty text becomes null so an
    /// edit can clear a value.
    private static func companyBody(_ d: CompanyDetails, previous: Job?) -> [String: Any] {
        func value(_ s: String) -> Any { s.isEmpty ? NSNull() : s }
        let website = CompanyLink.normalized(d.website)
        let careers = CompanyLink.normalized(d.careersURL)
        var body: [String: Any] = [
            "name": d.name,
            "sector": value(d.sector),
            "also_known_as": d.alsoKnownAs,
            "domains": d.domains,
            "website": website ?? NSNull(),
            "careers_url": careers ?? NSNull(),
            "logo_url": CompanyLink.normalized(d.logoURL) ?? NSNull(),
            "is_fresher": d.isFresher,
            "open_now": d.isFresher && d.isOpenNow,
            "company_type": value(d.companyType),
            "hiring_routes": d.orderedRoutes.map(\.rawValue),
            "route_category": RouteCategory.of(d.orderedRoutes)?.rawValue ?? NSNull(),
            "usually_opens": value(d.usuallyOpens),
            "batches": d.batches,
            "fresher_roles": d.fresherRoles
        ]
        // Where a link came from is kept with it: unchanged, it keeps its
        // source; changed by hand, it says so; cleared, there's nothing to source.
        if website != previous?.website.flatMap(CompanyLink.normalized) {
            body["website_source"] = website == nil ? NSNull() : "edited"
        }
        if careers != previous?.careersURL.flatMap(CompanyLink.normalized) {
            body["careers_source"] = careers == nil ? NSNull() : "edited"
        }
        return body
    }

    /// The body without the columns this database is known not to have yet.
    private static func stripMissingColumns(_ body: [String: Any]) -> [String: Any] {
        body.filter { key, _ in
            !(domainsColumnMissing && key == "domains") && !(fresherColumnsMissing && fresherColumns.contains(key))
                && !(alsoKnownAsColumnMissing && key == "also_known_as")
        }
    }

    /// After a write was refused for a missing column, mark the group it most
    /// likely belongs to as missing. False when there's nothing left to drop,
    /// so the caller rethrows instead of looping.
    private static func noteMissingColumn(in body: [String: Any]) -> Bool {
        // The newest migration is the likeliest one not to have run.
        if !alsoKnownAsColumnMissing && body["also_known_as"] != nil {
            alsoKnownAsColumnMissing = true
            return true
        }
        if !fresherColumnsMissing && body.keys.contains(where: fresherColumns.contains) {
            fresherColumnsMissing = true
            return true
        }
        if !domainsColumnMissing && body["domains"] != nil {
            domainsColumnMissing = true
            return true
        }
        return false
    }

    /// Replace just a company's domains.
    static func setDomains(companyID: String, domains: [String]) async throws {
        guard !domainsColumnMissing else { return }
        do {
            try await write(method: "PATCH", path: "companies",
                            query: [URLQueryItem(name: "id", value: "eq.\(companyID)")],
                            body: ["domains": domains])
        } catch SupabaseError.schemaOutOfDate {
            domainsColumnMissing = true
        }
    }

    /// Delete companies from the shared catalog, in one request. The database
    /// cascades this to their contacts and every user's tracked/sent rows.
    static func deleteCompanies(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await write(method: "DELETE", path: "companies",
                        query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")])
    }

    // MARK: - Hiring sources (shared)

    /// Set once the database reports it has no `company_sources` table — the
    /// fresher-hiring migration hasn't run — so screens can say so instead of
    /// showing an empty list as if there were no sources.
    private(set) static var sourcesTableMissing = false

    /// Every hiring source filed under a company, valid or not.
    static func fetchSources(companyID: String) async throws -> [CompanySource] {
        let request = makeRequest(path: "company_sources", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "company_id", value: "eq.\(companyID)"),
            URLQueryItem(name: "limit", value: "2000")
        ])
        do {
            let rows = try decoder.decode([CompanySource].self, from: try await send(request))
            sourcesTableMissing = false
            return rows
        } catch SupabaseError.schemaOutOfDate {
            sourcesTableMissing = true
            return []
        }
    }

    /// Add a source to a company and return its id.
    @discardableResult
    static func addSource(_ source: CompanySource) async throws -> String {
        var body = sourceBody(source)
        body["company_id"] = source.companyID
        return try await insertReturningID(path: "company_sources", body: body)
    }

    /// Save an edited source. Marked as edited, so a later import from the
    /// ledger doesn't put the old text back.
    static func updateSource(_ source: CompanySource) async throws {
        var body = sourceBody(source)
        body["edited_at"] = iso(Date())
        try await write(method: "PATCH", path: "company_sources",
                        query: [URLQueryItem(name: "id", value: "eq.\(source.id)")], body: body)
    }

    /// Mark sources valid or invalid, for every user. Separate from
    /// `updateSource`, as a contact's validity is from its edit: an ordinary
    /// edit never flips it back.
    static func setSourceValidity(ids: [String], isValid: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await write(method: "PATCH", path: "company_sources",
                        query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")],
                        body: ["is_valid": isValid])
    }

    static func deleteSources(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await write(method: "DELETE", path: "company_sources",
                        query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")])
    }

    /// A source row's editable columns. Empty text becomes null.
    private static func sourceBody(_ s: CompanySource) -> [String: Any] {
        func value(_ text: String?) -> Any {
            let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? NSNull() : t
        }
        return [
            "route": s.route,
            "role": value(s.role),
            "location": value(s.location),
            "batch": value(s.batch),
            "source_label": value(s.sourceLabel),
            // As the editor hands them over: tidied when typed, kept to the
            // letter when not, so an imported link is never rewritten.
            "url": value(s.url),
            "proof_url": value(s.proofURL),
            "posted_on": value(s.postedOn),
            "package_lpa": s.packageLPA ?? NSNull(),
            "package_text": value(s.packageText)
        ]
    }

    // MARK: - Export

    /// Every row of a table, a thousand to a request, exactly as the database
    /// holds it — every column, including ones this build doesn't know.
    static func fetchRows(_ path: String, filters: [URLQueryItem] = [], order: String) async throws -> [[String: Any]] {
        let page = 1000
        var rows: [[String: Any]] = []
        while true {
            let request = makeRequest(path: path, query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: order),
                URLQueryItem(name: "limit", value: String(page)),
                URLQueryItem(name: "offset", value: String(rows.count))
            ] + filters)
            let data = try await send(request)
            guard let batch = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw SupabaseError.badResponse
            }
            rows += batch
            if batch.count < page { return rows }
        }
    }

    // MARK: - Contact writes

    /// Add a contact to the user's own vault and return its id, so the caller
    /// can record a send. The id is made here, since it's sealed into the row.
    /// Nothing on the server can tell two sealed addresses apart, so the
    /// caller checks for a duplicate first (`JobStore.addContact`).
    @discardableResult
    static func addContact(companyID: String, contact: Contact) async throws -> String {
        let id = UUID().uuidString.lowercased()
        var body = try contactBody(contact, id: id)
        body["id"] = id
        body["company_id"] = companyID
        return try await insertReturningID(path: "recruiters", body: body)
    }

    /// Save a contact's fields. Only the owner's own contacts are written.
    /// The write only matches a row in this account's own vault, so a contact
    /// read from an import can't be taken over by saving it.
    static func updateContact(_ contact: Contact) async throws {
        guard contact.isOwned, let own = ownContacts() else { throw VaultError.notOwner }
        try await write(method: "PATCH", path: "recruiters",
                        query: [URLQueryItem(name: "id", value: "eq.\(contact.id)"), own],
                        body: try contactBody(contact, id: contact.id))
    }

    /// Flag contacts valid or invalid in the shared catalog — the whole set in
    /// one request. Deliberately separate from `updateContact` (and absent from
    /// `contactBody`) so an ordinary field edit can never silently flip validity
    /// back, e.g. when someone corrects a bad address before re-validating it.
    static func setContactValidity(ids: [String], isValid: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await write(method: "PATCH", path: "recruiters",
                        query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")],
                        body: ["is_valid": isValid])
    }

    /// Contacts by id, wherever they're filed, a hundred to a request. Ones
    /// this account can't read are left out.
    static func fetchContacts(ids: [String]) async throws -> [Contact] {
        // A hundred ids a request keeps the URL short, and the requests go out
        // together: one after another, a few hundred mailed contacts held up
        // every reply check by seconds before it had read a thing.
        let requests = stride(from: 0, to: ids.count, by: 100).map { start in
            makeRequest(path: "recruiters", query: [
                URLQueryItem(name: "select", value: "*"),
                readableContacts(under: nil),
                URLQueryItem(name: "id", value: "in.(\(ids[start..<min(start + 100, ids.count)].joined(separator: ",")))")
            ])
        }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            for request in requests {
                group.addTask { try await send(request) }
            }
            var contacts: [Contact] = []
            for try await data in group {
                contacts += try decoder.decode(LossyContacts.self, from: data).contacts
            }
            return contacts
        }
    }

    /// Every contact this account can read, with the company each is filed
    /// under: what searching contacts and matching an address's domain run
    /// over, now the server can't read either. A thousand rows a request (the
    /// server's cap), all in flight at once once the total is known.
    static func fetchContactDirectory() async throws -> [(companyID: String, contact: Contact)] {
        let filter = readableContacts(under: nil)
        // Checked like any other request: a refused count (an expired key, a
        // pending migration) says why rather than "Unexpected response".
        let total = try await count("recruiters", [filter])
        struct Row: Decodable {
            let companyID: String
            let contact: Contact
            private enum Key: String, CodingKey { case company_id }
            init(from decoder: Decoder) throws {
                companyID = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .company_id)
                contact = try Contact(from: decoder)
            }
        }
        struct Rows: Decodable {
            let rows: [Row]
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var kept: [Row] = []
                while !container.isAtEnd {
                    if let row = try? container.decode(Row.self) { kept.append(row) } else { _ = try? container.decode(Skipped.self) }
                }
                rows = kept
            }
        }
        let page = 1000
        let requests = stride(from: 0, to: total, by: page).map { offset in
            makeRequest(path: "recruiters", query: [
                URLQueryItem(name: "select", value: "*"), filter,
                URLQueryItem(name: "order", value: "id"),
                URLQueryItem(name: "limit", value: String(page)),
                URLQueryItem(name: "offset", value: String(offset))
            ])
        }
        let pages = try await withThrowingTaskGroup(of: Data.self) { group in
            for request in requests { group.addTask { try await send(request) } }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        var seen = Set<String>()
        var rows: [(companyID: String, contact: Contact)] = []
        for data in pages {
            for row in try decoder.decode(Rows.self, from: data).rows where seen.insert(row.contact.id).inserted {
                rows.append((row.companyID, row.contact))
            }
        }
        return rows
    }

    /// Delete several contacts in one request.
    static func deleteContacts(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        guard let own = ownContacts() else { throw VaultError.notOwner }
        try await write(method: "DELETE", path: "recruiters",
                        query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"), own])
    }

    // MARK: - Per-user sent records (mail_sends)

    /// Append a whole run's sends to this user's history in one request. Each
    /// send is a new row, so re-sending builds up the history rather than
    /// overwriting it.
    ///
    /// PostgREST takes an array, and a batch send is the common case — a hundred
    /// mails used to mean a hundred sequential round trips *after* the run, with
    /// the app's data stale until the last one landed. One request also makes the
    /// record atomic: previously a network drop halfway through left some of a
    /// run recorded and the rest not, and the unrecorded half would be offered up
    /// for sending again.
    static func recordSends(userEmail: String, records: [Contact.ID: SentMail],
                            at date: Date) async throws {
        guard !records.isEmpty else { return }
        func value(_ s: String?) -> Any { (s?.isEmpty ?? true) ? NSNull() : s! }

        // The subject and body are sealed under the account key; when it was
        // sent, to which contact, and Gmail's ids stay readable, so "already
        // mailed" holds whatever happens to the key.
        let rows: [[String: Any]] = try records.map { id, mail in
            let sendID = UUID().uuidString.lowercased()
            return [
                "id": sendID,
                "user_email": userEmail,
                "recruiter_id": id,
                "sent_at": iso(date),
                "sealed": try KeyRing.shared.sealPersonal(SealedMail(subject: mail.subject, body: mail.body),
                                                          context: Sealing.sendContext(id: sendID)),
                "gmail_message_id": value(mail.gmailMessageID),
                "gmail_thread_id": value(mail.gmailThreadID)
            ]
        }

        do {
            try await write(method: "POST", path: "mail_sends", rows: rows)
        } catch SupabaseError.schemaOutOfDate {
            // The reply-tracking columns aren't there yet. Record the sends
            // without them rather than losing them: an unrecorded send is a
            // contact who gets mailed a second time, which is far worse than
            // missing metadata.
            replyColumnsMissing = true
            let stripped = rows.map { row -> [String: Any] in
                var row = row
                row["gmail_message_id"] = nil
                row["gmail_thread_id"] = nil
                return row
            }
            try await write(method: "POST", path: "mail_sends", rows: stripped)
        }
    }

    /// Set once a write comes back reporting the reply columns don't exist, so the
    /// UI can point at the migration instead of showing a raw PostgREST error.
    private(set) static var replyColumnsMissing = false

    /// Attach Gmail's ids to a send recorded before the app captured them —
    /// recovered by searching the Sent mailbox (see `ReplySync`).
    static func attachThread(sendID: String, messageID: String, threadID: String) async throws {
        try await write(method: "PATCH", path: "mail_sends",
                        query: [URLQueryItem(name: "id", value: "eq.\(sendID)")],
                        body: ["gmail_message_id": messageID, "gmail_thread_id": threadID])
    }

    /// Record that someone answered this send. Written once — later syncs skip a
    /// row that already has a `replied_at`, so the first reply is the one kept.
    static func recordReply(sendID: String, at date: Date,
                            from sender: String, snippet: String?) async throws {
        let reply = SealedReply(from: sender, snippet: (snippet?.isEmpty ?? true) ? nil : snippet)
        let body: [String: Any] = [
            "replied_at": iso(date),
            "sealed_reply": try KeyRing.shared.sealPersonal(reply, context: Sealing.replyContext(id: sendID)),
            "reply_from": NSNull(),
            "reply_snippet": NSNull()
        ]
        try await write(method: "PATCH", path: "mail_sends",
                        query: [URLQueryItem(name: "id", value: "eq.\(sendID)")],
                        body: body)
    }

    /// Take back a reply that wasn't one — an auto-answer saying the address
    /// is no longer in service, recorded as a reply before those were known.
    static func clearReply(sendID: String) async throws {
        let body: [String: Any] = ["replied_at": NSNull(), "sealed_reply": NSNull(),
                                   "reply_from": NSNull(), "reply_snippet": NSNull()]
        try await write(method: "PATCH", path: "mail_sends",
                        query: [URLQueryItem(name: "id", value: "eq.\(sendID)")],
                        body: body)
    }

    // MARK: - Profile (per Gmail user)

    /// The profile, opened from its seal. Nil when there's none — or when it
    /// was sealed under an account key since replaced, which reads the same:
    /// the profile is asked for again.
    static func fetchProfile(email: String) async throws -> Profile? {
        let request = makeRequest(path: "profiles", query: [
            URLQueryItem(name: "select", value: "name,is_studying,college,is_working,company,position,resume_link,sealed"),
            URLQueryItem(name: "email", value: "eq.\(email)")
        ])
        let data = try await send(request)
        struct Row: Decodable { let sealed: String? }
        guard let row = try decoder.decode([Row].self, from: data).first else { return nil }
        guard let sealed = row.sealed else { return try decoder.decode([Profile].self, from: data).first }
        return KeyRing.shared.openPersonal(Profile.self, from: sealed, context: Sealing.profileContext(email: email))
    }

    /// The plain columns are blanked rather than nulled: empty says nothing,
    /// and it keeps whatever the table requires of them.
    static func upsertProfile(email: String, profile: Profile) async throws {
        let body: [String: Any] = [
            "email": email,
            "sealed": try KeyRing.shared.sealPersonal(profile, context: Sealing.profileContext(email: email)),
            "name": "",
            "is_studying": false,
            "college": "",
            "is_working": false,
            "company": "",
            "position": "",
            "resume_link": ""
        ]
        try await write(method: "POST", path: "profiles", body: body,
                        prefer: "return=minimal,resolution=merge-duplicates")
    }

    // MARK: - Templates (per Gmail user)

    /// This user's templates, opened from their seals, by name. One sealed
    /// under an account key since replaced is left out.
    static func fetchTemplates(userEmail: String) async throws -> [MailTemplate] {
        let request = makeRequest(path: "templates", query: [
            URLQueryItem(name: "select", value: "id,name,subject,content,sealed"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)")
        ])
        let data = try await send(request)
        struct Row: Decodable {
            let id: UUID
            let name: String?, subject: String?, content: String?, sealed: String?
        }
        return try decoder.decode([Row].self, from: data).compactMap { row -> MailTemplate? in
            if let sealed = row.sealed {
                guard let open = KeyRing.shared.openPersonal(SealedTemplate.self, from: sealed,
                                                             context: Sealing.templateContext(id: row.id.uuidString))
                else { return nil }
                return MailTemplate(id: row.id, name: open.name, subject: open.subject, content: open.content)
            }
            return MailTemplate(id: row.id, name: row.name ?? "", subject: row.subject ?? "", content: row.content ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func upsertTemplate(userEmail: String, template: MailTemplate) async throws {
        let sealed = SealedTemplate(name: template.name, subject: template.subject, content: template.content)
        let body: [String: Any] = [
            "id": template.id.uuidString,
            "user_email": userEmail,
            "sealed": try KeyRing.shared.sealPersonal(sealed, context: Sealing.templateContext(id: template.id.uuidString)),
            "name": NSNull(),
            "subject": NSNull(),
            "content": NSNull()
        ]
        try await write(method: "POST", path: "templates", body: body,
                        prefer: "return=minimal,resolution=merge-duplicates")
    }

    /// Delete templates in one request.
    static func deleteTemplates(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await write(method: "DELETE", path: "templates",
                        query: [URLQueryItem(name: "id", value: "in.(\(ids.map(\.uuidString).joined(separator: ",")))")])
    }

    /// A contact row body: its fields sealed into the user's own vault, and
    /// the plain columns emptied. Sent state lives in `mail_sends`, not here.
    static func contactBody(_ contact: Contact, id: String) throws -> [String: Any] {
        let (sealed, vaultID, keyID) = try KeyRing.shared.sealOwnContact(contact.sealedFields, id: id)
        return [
            "vault_id": vaultID,
            "key_id": keyID,
            "sealed": sealed,
            "name": NSNull(),
            "email": NSNull(),
            "position": NSNull(),
            "phone": NSNull(),
            "greeting_name": NSNull()
        ]
    }

    /// Only the contacts of vaults this account can read. `under` is where
    /// the contacts sit in the request: embedded under a company
    /// ("recruiters"), deeper ("companies.recruiters"), or the table itself
    /// (nil). With nothing unlocked it matches no vault at all.
    static func readableContacts(under path: String? = "recruiters") -> URLQueryItem {
        let vaults = KeyRing.shared.readableVaults.sorted()
        let list = vaults.isEmpty ? "00000000-0000-0000-0000-000000000000" : vaults.joined(separator: ",")
        return URLQueryItem(name: path.map { "\($0).vault_id" } ?? "vault_id", value: "in.(\(list))")
    }

    /// Only the contacts of this account's own vault. Nil before it's unlocked.
    static func ownContacts() -> URLQueryItem? {
        KeyRing.shared.ownVaultID.map { URLQueryItem(name: "vault_id", value: "eq.\($0)") }
    }

    // MARK: - Company links (sealed, one row per vault)

    /// Set once the database reports it has no `company_links` table: its
    /// migration hasn't run. The company screen leaves the links out until it has.
    private(set) static var companyLinksTableMissing = false

    /// A company's links as this account sees them: its own vault's when it
    /// has any, or else an imported vault's, which it can read but not change.
    struct CompanyLinksOnFile: Equatable {
        var links = KeyRing.CompanyLinks()
        /// This account's own row for the company, which a save rewrites.
        var ownRowID: String?
        /// Whether `links` are someone else's, from an imported vault.
        var isImported = false
        /// Whether an imported vault has links here, shown or not: clearing
        /// this account's own then keeps an empty row, or they'd come back.
        var hasImported = false
    }

    private struct CompanyLinksRow: Decodable {
        let id: String
        let vaultID: String
        let keyID: String
        let sealed: String
        enum CodingKeys: String, CodingKey {
            case id, sealed
            case vaultID = "vault_id"
            case keyID = "key_id"
        }
    }

    static func fetchCompanyLinks(companyID: String) async throws -> CompanyLinksOnFile {
        let request = makeRequest(path: "company_links", query: [
            URLQueryItem(name: "select", value: "id,vault_id,key_id,sealed"),
            URLQueryItem(name: "company_id", value: "eq.\(companyID)"),
            readableContacts(under: nil)
        ])
        let rows: [CompanyLinksRow]
        do {
            rows = try decoder.decode([CompanyLinksRow].self, from: try await send(request))
            companyLinksTableMissing = false
        } catch SupabaseError.schemaOutOfDate {
            companyLinksTableMissing = true
            return CompanyLinksOnFile()
        }
        func open(_ row: CompanyLinksRow) -> KeyRing.CompanyLinks? {
            try? KeyRing.shared.openCompanyLinks(row.sealed, id: row.id, vaultID: row.vaultID, keyID: row.keyID)
        }
        let imported = rows.filter { !KeyRing.shared.owns(vault: $0.vaultID) }
            .sorted { $0.vaultID < $1.vaultID }.lazy.compactMap(open).first { !$0.isEmpty }
        if let own = rows.first(where: { KeyRing.shared.owns(vault: $0.vaultID) }) {
            // One that won't open (sealed under a key this phone lacks) reads
            // as none; saving replaces it.
            return CompanyLinksOnFile(links: open(own) ?? KeyRing.CompanyLinks(), ownRowID: own.id,
                                      hasImported: imported != nil)
        }
        return CompanyLinksOnFile(links: imported ?? KeyRing.CompanyLinks(), isImported: imported != nil,
                                  hasImported: imported != nil)
    }

    /// Write a company's links into this account's own vault, sealed, and
    /// return the row's id. Empty links delete the row and return nil, unless
    /// `keepEmpty`: then the empty row stays, standing in front of an imported
    /// vault's links.
    static func saveCompanyLinks(companyID: String, links: KeyRing.CompanyLinks, rowID: String?,
                                 keepEmpty: Bool = false) async throws -> String? {
        guard let own = ownContacts() else { throw VaultError.notOwner }
        if links.isEmpty && !keepEmpty {
            if let rowID {
                try await write(method: "DELETE", path: "company_links",
                                query: [URLQueryItem(name: "id", value: "eq.\(rowID)"), own])
            }
            return nil
        }
        let id = rowID ?? UUID().uuidString.lowercased()
        let (sealed, vaultID, keyID) = try KeyRing.shared.sealOwnCompanyLinks(links, id: id)
        try await write(method: "POST", path: "company_links",
                        body: ["id": id, "company_id": companyID, "vault_id": vaultID, "key_id": keyID,
                               "sealed": sealed, "updated_at": iso(Date())],
                        prefer: "return=minimal,resolution=merge-duplicates", onConflict: "company_id,vault_id")
        return id
    }

    // MARK: - Plumbing

    static func makeRequest(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(string: "\(AppConfig.supabaseURL)/rest/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        // The bearer is set when the request goes out (`perform`): the
        // account's database session, made fresh if it has expired.
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        return request
    }

    @discardableResult
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            throw error(status: http.statusCode, body: data, request: request)
        }
        return data
    }

    /// Send `request` as this account. A session the server turns away as
    /// expired (PostgREST's PGRST30x) is renewed and the request sent once
    /// more; it was refused before anything ran, so sending it again is safe.
    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        var renewed = false
        while true {
            let bearer = await DatabaseSession.shared.bearer()
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SupabaseError.badResponse }
            if http.statusCode == 401, !renewed, bearer != AppConfig.supabaseAnonKey,
               String(decoding: data, as: UTF8.self).contains("PGRST30") {
                await DatabaseSession.shared.invalidate(bearer)
                renewed = true
                continue
            }
            return (data, http)
        }
    }

    /// What a failed request means, from its status and PostgREST's error body.
    private static func error(status: Int, body data: Data, request: URLRequest) -> SupabaseError {
        let body = String(data: data, encoding: .utf8) ?? "status \(status)"
        // Refused for who's asking (scripts/rls_migration.sql): no session the
        // server accepts, or a row this account may not change.
        if status == 401 { return .notSignedIn }
        if status == 403 || body.contains("\"42501\"") { return .notAllowed }
        // A foreign-key violation (23503) is a 409 too, and no duplicate: a
        // write pointing at a row since deleted (a contact added to a company
        // another phone just removed), or a delete of a row others still use.
        if body.contains("\"23503\"") {
            return request.httpMethod == "DELETE" ? .stillInUse : .missingParent
        }
        // A unique-constraint violation (Postgres 23505) means the row already
        // exists — surface a friendly message instead of raw SQL.
        if status == 409 || body.contains("\"23505\"") {
            return request.url?.lastPathComponent == "recruiters"
                ? .duplicateContact : .duplicateCompany
        }
        // PGRST204 (a column we wrote), 42703 (a column we filtered on),
        // PGRST205 / 42P01 (a table) or PGRST200 (a relationship): the schema
        // is behind this build. That's a pending migration, not a bug in the
        // request.
        if ["PGRST204", "\"42703\"", "PGRST205", "\"42P01\"", "PGRST200"].contains(where: body.contains) {
            return .schemaOutOfDate
        }
        return .server(body)
    }

    /// POST `body` and return the new row's `id`. When `onConflict` is given the
    /// insert upserts on those columns instead of failing on a duplicate.
    static func insertReturningID(path: String, body: [String: Any],
                                          onConflict: String? = nil) async throws -> String {
        var query: [URLQueryItem] = []
        var prefer = "return=representation"
        if let onConflict {
            query.append(URLQueryItem(name: "on_conflict", value: onConflict))
            prefer += ",resolution=merge-duplicates"
        }
        var request = makeRequest(path: path, query: query)
        request.httpMethod = "POST"
        request.setValue(prefer, forHTTPHeaderField: "Prefer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        struct Row: Decodable { let id: String }
        guard let row = try decoder.decode([Row].self, from: data).first else {
            throw SupabaseError.badResponse
        }
        return row.id
    }

    /// Insert several rows in one request.
    static func write(method: String, path: String, rows: [[String: Any]]) async throws {
        var request = makeRequest(path: path)
        request.httpMethod = method
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: rows)
        try await send(request)
    }

    static func write(method: String, path: String,
                              query: [URLQueryItem] = [], body: [String: Any]? = nil,
                              prefer: String = "return=minimal", onConflict: String? = nil) async throws {
        var query = query
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }
        var request = makeRequest(path: path, query: query)
        request.httpMethod = method
        request.setValue(prefer, forHTTPHeaderField: "Prefer")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        try await send(request)
    }

    // MARK: - Date handling

    static func iso(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    /// Made once: building an `ISO8601DateFormatter` costs far more than using
    /// one, and every timestamp in every load went through two fresh ones —
    /// several hundred per reload, on the main actor. (Formatters are safe to
    /// share once configured.)
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let raw = try dec.singleValueContainer().decode(String.self)
            if let date = parseTimestamp(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath,
                                                    debugDescription: "Unrecognized date: \(raw)"))
        }
        return decoder
    }()

    /// Parse a Postgres timestamptz, tolerating fractional seconds and the space
    /// separator Postgres sometimes emits instead of "T".
    private static func parseTimestamp(_ string: String) -> Date? {
        let normalized = string.replacingOccurrences(of: " ", with: "T")
        if let date = fractionalFormatter.date(from: normalized) { return date }
        let plain = plainFormatter
        if let date = plain.date(from: normalized) { return date }

        // Microsecond precision (6+ fractional digits) that ISO8601DateFormatter
        // rejects — trim the fractional part and retry.
        if let dot = normalized.firstIndex(of: "."),
           let tzStart = normalized[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let trimmed = String(normalized[..<dot]) + String(normalized[tzStart...])
            return plain.date(from: trimmed)
        }
        return nil
    }
}

enum SupabaseError: LocalizedError {
    case badResponse
    case duplicateCompany
    case duplicateContact
    /// The row a write points at (a contact's company) has been deleted.
    case missingParent
    /// A delete refused because other rows still point at the row.
    case stillInUse
    /// The request went out without a database session the server accepts.
    case notSignedIn
    /// A row this account may not change: another account's, or a contact
    /// someone else added.
    case notAllowed
    /// The database is missing a column this build uses — one of the migrations
    /// in the README hasn't been run yet.
    case schemaOutOfDate
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the server."
        case .duplicateCompany: return "A company with that name already exists."
        case .duplicateContact: return "A contact with that email already exists at this company."
        case .missingParent: return "That company has been deleted. Refresh and try again."
        case .stillInUse: return "Other records still use this, so it can't be deleted. Refresh and try again."
        case .notSignedIn: return "The database didn't accept this account's sign-in. Reconnect Gmail in Settings."
        case .notAllowed: return "This account can't change that. Only the person who added it can."
        case .schemaOutOfDate:
            return "The database is missing columns this version of the app uses. Run the migrations in the README."
        case .server(let message): return message
        }
    }
}

extension Error {
    /// True when a request was cancelled (e.g. a view-driven reload was
    /// interrupted by a tab switch) — never a real failure worth surfacing.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
