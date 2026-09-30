import Foundation

/// Talks to Supabase's auto-generated REST API (PostgREST). Companies and
/// contacts are a shared catalog; each user's Home selection
/// (`tracked_companies`), sent records (`mail_sends`), profile and templates are
/// rows keyed by their Gmail address.
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
    static func fetchAllCompanies(limit: Int = defaultPageSize, offset: Int = 0) async throws -> [Job] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
            URLQueryItem(name: "order", value: "name")
        ]
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
        }
        return try decoder.decode([Job].self, from: data)
    }

    private struct ColumnProbe: Decodable {
        let hasDomains: Bool
        private enum Key: String, CodingKey { case domains }
        init(from decoder: Decoder) throws {
            hasDomains = try decoder.container(keyedBy: Key.self).contains(.domains)
        }
    }

    /// Search the shared catalog for companies matching a query string across company name,
    /// sector, domain, and contact name/email/position.
    static func searchCompanies(query: String, limit: Int = defaultPageSize) async throws -> [Job] {
        // Characters that carry meaning in a PostgREST `or=(…)` filter would change
        // the shape of the filter rather than the value searched for.
        let reserved = CharacterSet(charactersIn: ",()*\"\\%")
        let cleaned = query.components(separatedBy: reserved).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return [] }
        let pattern = "*\(cleaned)*"

        // 1. Companies by name or sector — and by domain, when the query is one.
        // 2. Companies that employ a matching contact (by name, email or
        //    position). Independent of the first search, so both are in flight
        //    at once.
        let contactReq = makeRequest(path: "recruiters", query: [
            URLQueryItem(name: "select", value: "company_id"),
            URLQueryItem(name: "or", value: "(name.ilike.\(pattern),email.ilike.\(pattern),position.ilike.\(pattern))"),
            URLQueryItem(name: "limit", value: String(limit))
        ])
        async let byCompany = searchCompanyRows(pattern: pattern, domain: MailDomain.clean(cleaned), limit: limit)
        async let byContact = send(contactReq)
        var foundCompanies = try await byCompany
        let employers = try decoder.decode([CompanyRef].self, from: try await byContact)
        foundCompanies += try await fetchCompanies(ids: Set(employers.compactMap(\.company_id))
                                                        .subtracting(foundCompanies.map(\.id)))
        return foundCompanies.sortedByName()
    }

    /// Companies whose name or sector matches `pattern`, or that list `domain`.
    /// The domains column only exists once its migration has run; without it
    /// the filter is rejected, so this retries without it rather than failing
    /// the whole search.
    private static func searchCompanyRows(pattern: String, domain: String?, limit: Int) async throws -> [Job] {
        func request(includingDomains: Bool) -> URLRequest {
            var filters = ["name.ilike.\(pattern)", "sector.ilike.\(pattern)"]
            if includingDomains, let domain { filters.append("domains.cs.{\(domain)}") }
            return makeRequest(path: "companies", query: [
                URLQueryItem(name: "select", value: "*,recruiters(*)"),
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
    /// and the ones with a contact at that domain. Used to point a new contact at
    /// the company it most likely belongs to, so the same company never gets
    /// entered twice under two names.
    static func companies(forDomain domain: String) async throws -> [Job] {
        guard MailDomain.isWellFormed(domain) else { return [] }
        // The two lookups are independent, so both are in flight at once.
        let contactReq = makeRequest(path: "recruiters", query: [
            URLQueryItem(name: "select", value: "company_id"),
            URLQueryItem(name: "email", value: "ilike.*@\(domain)"),
            URLQueryItem(name: "limit", value: "200")
        ])
        async let listed = companiesListing(domain)
        async let byContact = send(contactReq)
        var found = try await listed
        let employers = try decoder.decode([CompanyRef].self, from: try await byContact)
        found += try await fetchCompanies(ids: Set(employers.compactMap(\.company_id)).subtracting(found.map(\.id)))
        return found
    }

    /// The companies with `domain` on their row. Empty until the domains
    /// migration has run.
    private static func companiesListing(_ domain: String) async throws -> [Job] {
        guard !domainsColumnMissing else { return [] }
        let request = makeRequest(path: "companies", query: [
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
            URLQueryItem(name: "domains", value: "cs.{\(domain)}")
        ])
        do {
            return try decoder.decode([Job].self, from: try await send(request))
        } catch SupabaseError.schemaOutOfDate {
            domainsColumnMissing = true
            return []
        }
    }

    /// A contact row reduced to the company it belongs to.
    private struct CompanyRef: Decodable { let company_id: String? }

    /// Companies by id, with their contacts. One request; none when `ids` is empty.
    private static func fetchCompanies(ids: Set<String>) async throws -> [Job] {
        guard !ids.isEmpty else { return [] }
        let request = makeRequest(path: "companies", query: [
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
            URLQueryItem(name: "id", value: "in.(\(ids.sorted().joined(separator: ",")))")
        ])
        return try decoder.decode([Job].self, from: try await send(request))
    }

    /// Fetch a single company by id from Supabase with all contacts and sector.
    static func fetchCompany(id: String) async throws -> Job? {
        let request = makeRequest(path: "companies", query: [
            URLQueryItem(name: "select", value: "*,recruiters(*)"),
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
    static func fetchSends(userEmail: String, limit: Int = defaultPageSize, offset: Int = 0) async throws -> [MailSend] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "order", value: "sent_at.desc")
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
    static func fetchActivity(sends: [MailSend]) async throws -> [ActivityEntry] {
        guard !sends.isEmpty else { return [] }
        let allIDs = Array(Set(sends.map(\.contactID)))

        struct Row: Decodable {
            let id: String
            let name: String?
            let email: String?
            let position: String?
            struct Company: Decodable { let name: String }
            let companies: Company?
        }

        // 50 ids per request (a longer `in.(…)` list overflows the URL), all
        // chunks at once rather than one after another.
        let requests = stride(from: 0, to: allIDs.count, by: defaultPageSize).map { start in
            makeRequest(path: "recruiters", query: [
                URLQueryItem(name: "select", value: "id,name,email,position,companies(name)"),
                URLQueryItem(name: "id", value: "in.(\(allIDs[start..<min(start + defaultPageSize, allIDs.count)].joined(separator: ",")))")
            ])
        }
        let pages = try await withThrowingTaskGroup(of: Data.self) { group in
            for request in requests { group.addTask { try await send(request) } }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        var byID: [String: Row] = [:]
        for page in pages {
            for row in try decoder.decode([Row].self, from: page) { byID[row.id] = row }
        }

        // One entry per send, keyed by the send's own id (unique per send).
        return sends.compactMap { send -> ActivityEntry? in
            guard let row = byID[send.contactID] else { return nil }
            let contact = Contact(id: row.id, email: row.email ?? "", name: row.name ?? "",
                                  position: row.position ?? "", isSent: true, sentAt: send.sentAt,
                                  sentSubject: send.subject, sentBody: send.body,
                                  repliedAt: send.repliedAt, replyFrom: send.replyFrom,
                                  replySnippet: send.replySnippet)
            return ActivityEntry(id: send.id, company: row.companies?.name ?? "", contact: contact)
        }
    }

    // MARK: - Company catalog writes

    /// Set once the database reports it has no `companies.domains` column — the
    /// migration in the README hasn't run. Domains can't be stored until it has,
    /// so the store tells the user rather than dropping them silently.
    private(set) static var domainsColumnMissing = false

    /// Create a company in the catalog and return its new id. The company is
    /// created even when its domains can't be stored (see `domainsColumnMissing`).
    static func addCompany(name: String, sector: String?, domains: [String] = []) async throws -> String {
        var body: [String: Any] = ["name": name]
        if let sector, !sector.isEmpty { body["sector"] = sector }
        if !domains.isEmpty, !domainsColumnMissing { body["domains"] = domains }
        do {
            return try await insertReturningID(path: "companies", body: body)
        } catch SupabaseError.schemaOutOfDate where body["domains"] != nil {
            domainsColumnMissing = true
            body.removeValue(forKey: "domains")
            return try await insertReturningID(path: "companies", body: body)
        }
    }

    /// Rename, re-sector, or replace the domains of a catalog company. Empty
    /// sector clears the column; nil `domains` leaves them untouched.
    static func updateCompany(id: String, name: String, sector: String?, domains: [String]? = nil) async throws {
        var body: [String: Any] = [
            "name": name,
            "sector": (sector?.isEmpty ?? true) ? NSNull() : sector!
        ]
        if let domains, !domainsColumnMissing { body["domains"] = domains }
        let query = [URLQueryItem(name: "id", value: "eq.\(id)")]
        do {
            try await write(method: "PATCH", path: "companies", query: query, body: body)
        } catch SupabaseError.schemaOutOfDate where body["domains"] != nil {
            domainsColumnMissing = true
            body.removeValue(forKey: "domains")
            try await write(method: "PATCH", path: "companies", query: query, body: body)
        }
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

    // MARK: - Contact writes

    /// Add a contact (upserting on (company_id, email) so it's identified by
    /// email within a company) and return its id, so the caller can record a send.
    @discardableResult
    static func addContact(companyID: String, contact: Contact) async throws -> String {
        var body = contactBody(contact)
        body["company_id"] = companyID
        do {
            return try await insertReturningID(path: "recruiters", body: body,
                                               onConflict: "company_id,email")
        } catch SupabaseError.schemaOutOfDate where !greetingColumnMissing {
            greetingColumnMissing = true
            return try await insertReturningID(path: "recruiters",
                                               body: withoutGreetingName(body),
                                               onConflict: "company_id,email")
        }
    }

    static func updateContact(_ contact: Contact) async throws {
        let query = [URLQueryItem(name: "id", value: "eq.\(contact.id)")]
        do {
            try await write(method: "PATCH", path: "recruiters", query: query,
                            body: contactBody(contact))
        } catch SupabaseError.schemaOutOfDate where !greetingColumnMissing {
            greetingColumnMissing = true
            try await write(method: "PATCH", path: "recruiters", query: query,
                            body: withoutGreetingName(contactBody(contact)))
        }
    }

    /// Set once a write comes back reporting `greeting_name` doesn't exist. The
    /// rest of the row is saved regardless — losing a whole contact edit over an
    /// optional greeting override would be the worse trade — and the greeting
    /// falls back to what `RecipientName` derives, as it did before the column.
    private(set) static var greetingColumnMissing = false

    private static func withoutGreetingName(_ body: [String: Any]) -> [String: Any] {
        var body = body
        body["greeting_name"] = nil
        return body
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

    /// Delete several contacts in one request.
    static func deleteContacts(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await write(method: "DELETE", path: "recruiters",
                        query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")])
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

        let rows: [[String: Any]] = records.map { id, mail in
            [
                "user_email": userEmail,
                "recruiter_id": id,
                "sent_at": iso(date),
                "subject": value(mail.subject),
                "body": value(mail.body),
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
        let body: [String: Any] = [
            "replied_at": iso(date),
            "reply_from": sender,
            "reply_snippet": (snippet?.isEmpty ?? true) ? NSNull() : snippet!
        ]
        try await write(method: "PATCH", path: "mail_sends",
                        query: [URLQueryItem(name: "id", value: "eq.\(sendID)")],
                        body: body)
    }

    // MARK: - Profile (per Gmail user)

    static func fetchProfile(email: String) async throws -> Profile? {
        let request = makeRequest(path: "profiles", query: [
            URLQueryItem(name: "select", value: "name,is_studying,college,is_working,company,position,resume_link"),
            URLQueryItem(name: "email", value: "eq.\(email)")
        ])
        let data = try await send(request)
        return try decoder.decode([Profile].self, from: data).first
    }

    static func upsertProfile(email: String, profile: Profile) async throws {
        let body: [String: Any] = [
            "email": email,
            "name": profile.name,
            "is_studying": profile.isStudying,
            "college": profile.college,
            "is_working": profile.isWorking,
            "company": profile.company,
            "position": profile.position,
            "resume_link": profile.resumeLink
        ]
        try await write(method: "POST", path: "profiles", body: body,
                        prefer: "return=minimal,resolution=merge-duplicates")
    }

    // MARK: - Templates (per Gmail user)

    static func fetchTemplates(userEmail: String) async throws -> [MailTemplate] {
        let request = makeRequest(path: "templates", query: [
            URLQueryItem(name: "select", value: "id,name,subject,content"),
            URLQueryItem(name: "user_email", value: "eq.\(userEmail)"),
            URLQueryItem(name: "order", value: "name")
        ])
        let data = try await send(request)
        return try decoder.decode([MailTemplate].self, from: data)
    }

    static func upsertTemplate(userEmail: String, template: MailTemplate) async throws {
        let body: [String: Any] = [
            "id": template.id.uuidString,
            "user_email": userEmail,
            "name": template.name,
            "subject": template.subject,
            "content": template.content
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

    /// A contact row body. Empty text fields become null so edits can clear a
    /// value. Sent state lives in `mail_sends`, not here.
    /// Once `greeting_name` is known to be missing it's left out up front, so
    /// every later save costs one request rather than a failure and a retry.
    private static func contactBody(_ contact: Contact) -> [String: Any] {
        func value(_ s: String?) -> Any { (s?.isEmpty ?? true) ? NSNull() : s! }
        let body: [String: Any] = [
            "name": value(contact.name),
            "email": value(contact.email),
            "position": value(contact.position),
            "phone": value(contact.phone),
            "greeting_name": value(contact.greetingName)
        ]
        return greetingColumnMissing ? withoutGreetingName(body) : body
    }

    // MARK: - Plumbing

    private static func makeRequest(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(string: "\(AppConfig.supabaseURL)/rest/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            // A unique-constraint violation (Postgres 23505) means the row already
            // exists — surface a friendly message instead of raw SQL.
            if http.statusCode == 409 || body.contains("\"23505\"") {
                throw request.url?.lastPathComponent == "recruiters"
                    ? SupabaseError.duplicateContact : SupabaseError.duplicateCompany
            }
            // PGRST204 (a column we wrote) or 42703 (a column we filtered on):
            // PostgREST knows the table but not the column. That's a pending
            // migration, not a bug in the request.
            if body.contains("PGRST204") || body.contains("\"42703\"") {
                throw SupabaseError.schemaOutOfDate
            }
            throw SupabaseError.server(body)
        }
        return data
    }

    /// POST `body` and return the new row's `id`. When `onConflict` is given the
    /// insert upserts on those columns instead of failing on a duplicate.
    private static func insertReturningID(path: String, body: [String: Any],
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
    private static func write(method: String, path: String, rows: [[String: Any]]) async throws {
        var request = makeRequest(path: path)
        request.httpMethod = method
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: rows)
        try await send(request)
    }

    private static func write(method: String, path: String,
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

    private static func iso(_ date: Date) -> String {
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

    private static let decoder: JSONDecoder = {
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
    /// The database is missing a column this build uses — one of the migrations
    /// in the README hasn't been run yet.
    case schemaOutOfDate
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the server."
        case .duplicateCompany: return "A company with that name already exists."
        case .duplicateContact: return "A contact with that email already exists at this company."
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
