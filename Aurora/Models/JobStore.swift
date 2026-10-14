import Foundation
import Observation

/// The app's data layer. Companies and contacts are a shared catalog in
/// Supabase; each Gmail user tracks a subset of companies (by id) and has their
/// own per-user "sent" state, overlaid onto the catalog at load time. Every
/// mutation writes to the database and then reloads, so on-screen state always
/// mirrors what's stored.
@Observable
final class JobStore {
    /// The user's tracked companies, with contacts and sent state. Drives Home's
    /// "Tracking" section.
    private(set) var jobs: [Job] = [] {
        didSet { trackedIDs = Set(jobs.map(\.id)) }
    }
    /// `jobs`' ids, so "is this tracked?" — asked by every row of the catalog —
    /// is a lookup rather than a scan.
    private var trackedIDs = Set<String>()
    /// Every company in the shared catalog, with contacts and this user's sent
    /// state overlaid. Drives the Companies list.
    private(set) var allCompanies: [Job] = []
    /// Companies opened directly (a deep link, an Activity row) that sit beyond
    /// the catalog pages loaded so far. Kept apart from `allCompanies` so the
    /// paged, name-sorted list never has rows spliced into the middle of it.
    private var detachedCompanies: [String: Job] = [:]
    /// The Activity feed: every contact the user has sent to, newest first.
    /// Loaded from the send history, so it's independent of which companies are
    /// currently tracked on Home.
    private(set) var activity: [ActivityEntry] = []
    /// This user's raw send rows, kept so reply syncing can work out which sends
    /// still need a thread id or a reply check.
    private(set) var sends: [MailSend] = []
    private(set) var isLoading = false
    var errorMessage: String?

    // MARK: - Catalog paging
    //
    // Only the catalog is paged. The send history is always fetched whole:
    // reply counts and the "already mailed" checks are only right when they
    // see every send.

    private(set) var hasMoreCompanies = true
    private(set) var isLoadingMoreCompanies = false
    /// How many catalog rows have been paged in from the server.
    private var companyOffset = 0

    /// Which slice of the catalog the Companies tab lists. Changing it pages
    /// the catalog in again from the server (see `setScope`).
    private(set) var catalogScope = CatalogScope.all
    /// How many companies each scope holds, for the filter chips. Missing until
    /// counted; best-effort, so a failed count leaves the chip without a figure.
    private(set) var scopeCounts: [CatalogScope: Int] = [:]
    /// The first pages of each scope already fetched, so a chip tap shows its
    /// list the same frame instead of waiting on the network. Always refreshed
    /// behind the scenes after it's shown (see `setScope`).
    private struct CatalogPage {
        var companies: [Job]
        var offset: Int
        var hasMore: Bool
    }
    @ObservationIgnored private var scopePages: [CatalogScope: CatalogPage] = [:]

    // MARK: - Hiring sources

    /// Each company's hiring sources, once its screen has asked for them. Loaded
    /// per company rather than with the catalog: a company can have a hundred,
    /// and the lists only ever need the company's own fields.
    private(set) var sources: [String: [CompanySource]] = [:]
    /// Companies whose sources are being fetched right now.
    private(set) var loadingSources: Set<String> = []

    // MARK: - Server search

    /// Catalog matches from the server for `searchQuery`, covering companies on
    /// pages that haven't been loaded yet.
    private(set) var searchResults: [Job] = []
    private(set) var isSearchingServer = false
    private var searchQuery = ""

    /// The connected Gmail address whose data we show. Set on sign-in.
    var userEmail: String?

    private var inFlight = 0
    /// True while a write and its confirming reload are in progress.
    var isSaving: Bool { inFlight > 0 }

    // MARK: - Home selection (synced per account)

    /// Which companies are on Home now lives server-side in `tracked_companies`,
    /// keyed by account email, so a user's selection follows them across devices.
    /// This on-device copy is a cache: it lets Home render its membership instantly
    /// and survive an offline launch, but the server is the source of truth and
    /// overwrites it on every successful load.
    private let trackedFile = JSONFile<[String: [String]]>(name: "home_companies.json")
    private var trackedByEmail: [String: [String]]

    init() {
        trackedByEmail = trackedFile.load() ?? [:]
    }

    /// Mutate and persist the current user's cached tracked ids (local only — the
    /// matching server write is fired separately by the caller).
    private func mutateTracked(_ transform: (inout [String]) -> Void) {
        guard let email = userEmail else { return }
        var ids = trackedByEmail[email] ?? []
        transform(&ids)
        trackedByEmail[email] = ids
        trackedFile.save(trackedByEmail)
    }

    /// Push a membership change to the server in the background so the UI never
    /// waits on the network. Best-effort: a failed push is surfaced, and the next
    /// full load reconciles against the server either way.
    private func pushTracked(add: Bool, companyID: String, email: String) {
        Task {
            do {
                if add {
                    try await SupabaseAPI.addTracked(userEmail: email, companyID: companyID)
                } else {
                    try await SupabaseAPI.removeTracked(userEmail: email, companyID: companyID)
                }
            } catch {
                report(error)
            }
        }
    }

    /// Whether this account's pre-sync, on-device selection has been lifted up to
    /// the server yet. Tracked in UserDefaults so it runs exactly once per account.
    private func hasMigrated(_ email: String) -> Bool {
        UserDefaults.standard.bool(forKey: "home.synced.\(email)")
    }

    private func markMigrated(_ email: String) {
        UserDefaults.standard.set(true, forKey: "home.synced.\(email)")
    }

    func clearError() { errorMessage = nil }

    // MARK: - Lookups

    /// A company by id, from the full catalog first (most complete) and then the
    /// tracked list — so a detail screen works whether or not it's tracked.
    func company(id: String) -> Job? {
        allCompanies.first { $0.id == id } ?? jobs.first { $0.id == id }
            ?? detachedCompanies[id] ?? searchResults.first { $0.id == id }
    }

    /// A contact by id, from any company held in memory. Walks the sources in
    /// place rather than through `knownCompanies`, which copies and de-duplicates
    /// every company on each call — and screens ask this from their body.
    func contact(id: Contact.ID) -> Contact? {
        for source in [allCompanies, jobs, Array(detachedCompanies.values), searchResults] {
            for company in source {
                if let match = company.contacts.first(where: { $0.id == id }) { return match }
            }
        }
        return nil
    }

    /// Load a specific company by id from Supabase if it isn't already in memory.
    @discardableResult
    func loadCompanyIfNeeded(id: String) async -> Job? {
        if let existing = company(id: id) { return existing }
        guard let fetched = try? await SupabaseAPI.fetchCompany(id: id) else { return nil }
        let company = Self.overlaying(latestSendByContact, onto: fetched)
        detachedCompanies[id] = company
        return company
    }

    /// Search the full catalog on Supabase for companies matching `query` (by name,
    /// sector, or contact info), overlaying user send state onto any returned items.
    ///
    /// Meant to be driven from `.task(id: query)`: typing cancels the previous
    /// call, and the short sleep up front debounces keystrokes so only a pause
    /// in typing reaches the server.
    func searchCompanies(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchQuery = ""
            searchResults = []
            isSearchingServer = false
            return
        }

        isSearchingServer = true
        guard await Task.debounce(.milliseconds(250)) else { return }

        do {
            var results = try await SupabaseAPI.searchCompanies(query: trimmed)
            guard !Task.isCancelled else { return }
            overlaySends(latestSendByContact, into: &results)
            searchQuery = trimmed
            searchResults = results
        } catch {
            // A failed search leaves the in-memory matches on screen; it isn't
            // worth an alert over a keystroke.
            guard !Task.isCancelled else { return }
        }
        isSearchingServer = false
    }

    /// Whether the company is on this user's Home.
    func isTracked(_ id: String) -> Bool {
        trackedIDs.contains(id)
    }


    // MARK: - Loading

    /// Load the user's tracked companies and the full catalog (both with contacts
    /// + sent state), plus the Activity feed.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await reloadAll()
        } catch {
            report(error)
        }
        isLoading = false
    }

    /// Ask Gmail what came back, then reload only if it found something.
    ///
    /// The reload is conditional because a sync that turns up nothing new has
    /// nothing to show, and refetching the whole catalog would flash every screen
    /// for no reason.
    ///
    /// The same check names the people mailed who have no name on file: the
    /// name they signed a reply with, or what the account's own mail calls
    /// them ("Aryan Kadian <kdaryan@acme.com>"), is saved to their contact.
    ///
    /// `reloadingFirst` reloads everything before reading Gmail, for a check
    /// someone asked for. The reload and the fetch of who has no name are part
    /// of the check, so it shows as running from the tap.
    func syncReplies(using sync: ReplySync, forceFullCheck: Bool = false, reloadingFirst: Bool = false) async {
        var unnamed: [Contact] = []
        let outcome = await sync.run(forceFullCheck: forceFullCheck) {
            if reloadingFirst { await load() }
            unnamed = await mailedContactsWithoutNames()
            return ReplySync.Inputs(sends: sends,
                                    emailByContact: emailByContact,
                                    excludingContactIDs: Set(knownCompanies.flatMap(\.invalidContacts).map(\.id)),
                                    lookingUpNames: unnamed.map(\.email))
        }
        // Deliberately `reloadSendsOnly()`: re-fetching the entire companies catalog
        // is unnecessary when only per-user sent/reply records have changed.
        if outcome.changedAnything {
            do {
                try await reloadSendsOnly()
            } catch {
                report(error)
            }
        }
        // Run after the reload, so a reply found just now can name them too.
        if await nameFromMail(unnamed) > 0 {
            do {
                try await reloadAll()
            } catch {
                report(error)
            }
        }
    }

    /// Look for bounces to a batch's mail while it's still sending, from
    /// `since` (when the run began). Quiet: see `ReplySync.checkBouncesWhileSending`.
    func checkBouncesWhileSending(using sync: ReplySync, since: Date) async {
        await sync.checkBouncesWhileSending(sends: sends, emailByContact: emailByContact, since: since)
    }

    /// The contacts this account has mailed whose name field gives no name:
    /// empty, or the mailbox copied over. Fetched by id, since a mailed
    /// contact's company may not be loaded.
    private func mailedContactsWithoutNames() async -> [Contact] {
        let ids = Array(Set(sends.map(\.contactID))).sorted()
        guard !ids.isEmpty, let contacts = try? await SupabaseAPI.fetchContacts(ids: ids) else { return [] }
        return contacts.filter { contact in
            let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return contact.isMailable && (name.isEmpty || RecipientName.isMailboxCopy(name, of: contact.email))
        }
    }

    /// Save a name to each of `contacts` that their own reply or this account's
    /// mail gives them. Returns how many were named.
    private func nameFromMail(_ contacts: [Contact]) async -> Int {
        var replyFrom: [Contact.ID: String] = [:]
        for send in sends where send.replyFrom != nil && replyFrom[send.contactID] == nil {
            replyFrom[send.contactID] = send.replyFrom
        }
        var named = 0
        for contact in contacts {
            let entries = [replyFrom[contact.id], MailboxNames.shared.entry(for: contact.email)].compactMap { $0 }
            guard let name = entries.lazy.compactMap({ RecipientName.fullName(in: $0, for: contact.email) }).first
            else { continue }
            do {
                try await SupabaseAPI.fillContactName(id: contact.id, name: name, replacing: contact.name)
                named += 1
            } catch {
                continue  // tried again on the next check
            }
        }
        return named
    }

    /// Look for one sent mail's bounce now (`ReplySync.checkBounce`).
    func checkBounce(sendID: String, using sync: ReplySync) async -> ReplySync.BounceCheck {
        guard let send = sends.first(where: { $0.id == sendID }),
              let address = emailByContact[send.contactID] else {
            return .failed("This mail isn't in your send history, so there's nothing to check it against.")
        }
        return await sync.checkBounce(of: send, address: address, sends: sends, emailByContact: emailByContact)
    }

    // MARK: - Tracking (home selection, syncs per account)

    /// Track a company on this user's Home. Optimistic: it appears in the tracked
    /// list immediately (reusing the full catalog row we already have), with the
    /// server write fired in the background.
    func track(companyID: String) {
        guard let email = userEmail else { return }
        guard !isTracked(companyID) else { return }
        mutateTracked { if !$0.contains(companyID) { $0.append(companyID) } }
        if let company = company(id: companyID) {
            insertSorted(company)
        }
        pushTracked(add: true, companyID: companyID, email: email)
    }

    /// Untrack a company from this user's Home. Instant + background push; the
    /// shared catalog (and anyone else's Home) is untouched.
    func untrack(companyID: String) {
        guard let email = userEmail else { return }
        mutateTracked { $0.removeAll { $0 == companyID } }
        jobs.removeAll { $0.id == companyID }
        pushTracked(add: false, companyID: companyID, email: email)
    }

    /// Track several companies at once (Companies multi-select).
    func trackCompanies(_ ids: [String]) {
        for id in ids { track(companyID: id) }
    }

    /// Untrack via a `Job` — powers Home's swipe-to-remove.
    func deleteJob(_ job: Job) { untrack(companyID: job.id) }

    /// Re-track a company that was just removed from Home — powers the Undo action.
    func restoreJob(_ job: Job) {
        guard let email = userEmail else { return }
        mutateTracked { if !$0.contains(job.id) { $0.append(job.id) } }
        pushTracked(add: true, companyID: job.id, email: email)
        insertSorted(job)
    }

    /// Insert a job keeping the alphabetical order Home displays.
    private func insertSorted(_ job: Job) {
        guard !isTracked(job.id) else { return }
        jobs = (jobs + [job]).sortedByName()
    }

    // MARK: - Catalog mutations (shared, upstream — change the DB for everyone)

    /// Create a new company in the shared catalog. Not auto-tracked; it appears in
    /// the Companies list (with "Show empty" on) ready for contacts.
    func createCompany(name: String, sector: String? = nil, domains: [String] = []) async {
        var details = CompanyDetails()
        details.name = name
        details.sector = sector ?? ""
        details.domains = domains
        await createCompany(details)
    }

    /// Create a company with everything the form was given.
    func createCompany(_ details: CompanyDetails) async {
        let details = details.trimmed
        guard !details.name.isEmpty else { return }
        await perform {
            _ = try await SupabaseAPI.addCompany(details)
        }
        warnIfDomainsDropped(details.domains)
        warnIfFresherDetailsDropped(details, previous: nil)
    }

    /// Save a catalog company's details (upstream, for everyone), with a short
    /// window to undo it.
    func updateCompany(id: String, details: CompanyDetails) async {
        let details = details.trimmed
        guard !details.name.isEmpty else { return }
        let previous = company(id: id)

        let saved = await perform {
            try await SupabaseAPI.updateCompany(id: id, details: details, previous: previous)
        }
        if saved, details.domains != previous?.domains { warnIfDomainsDropped(details.domains) }
        if saved { warnIfFresherDetailsDropped(details, previous: previous) }
        // Only a write that landed has anything to undo.
        guard saved, let previous else { return }
        UndoCoordinator.shared.stage(message: "Company details updated") { [weak self] in
            await self?.perform {
                // Restored as it was — including where its links came from.
                try await SupabaseAPI.updateCompany(id: id, details: previous.details, previous: nil)
                try await SupabaseAPI.restoreLinkSources(id: id, website: previous.websiteSource,
                                                         careers: previous.careersSource)
            }
        }
    }

    /// Rename, re-sector, or change the domains of a catalog company (upstream,
    /// for everyone), with a short window to undo it.
    func updateCompany(id: String, name: String, sector: String?, domains: [String]) async {
        guard var details = company(id: id)?.details else { return }
        details.name = name
        details.sector = sector ?? ""
        details.domains = domains
        await updateCompany(id: id, details: details)
    }

    /// Fresher details that couldn't be stored (the database predates their
    /// columns) are a partial save, and say so.
    private func warnIfFresherDetailsDropped(_ details: CompanyDetails, previous: Job?) {
        guard SupabaseAPI.fresherColumnsMissing, details.hasFresherDetails || previous?.details.hasFresherDetails == true
        else { return }
        errorMessage = "The company was saved, but its links, logo and fresher-hiring details weren't: the database needs a one-time update first. Run the fresher-hiring migration from the README in the Supabase SQL editor."
    }

    /// A company saved without the domains it was given (the database predates
    /// the column) is a partial save, and has to say so — the form closed as if
    /// everything had landed.
    private func warnIfDomainsDropped(_ domains: [String]) {
        guard !domains.isEmpty, SupabaseAPI.domainsColumnMissing else { return }
        errorMessage = "The company was saved, but its mail domains weren't: the database needs a one-time update first. Run the “companies.domains” migration from the README in the Supabase SQL editor."
    }

    /// Delete catalog companies (upstream, for everyone) in one request and one
    /// reload. The reload reconciles the tracked cache against server truth, so
    /// they drop off Home too.
    func deleteCompanies(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        await perform { try await SupabaseAPI.deleteCompanies(ids: ids) }
    }

    /// Every company already on file for a mail domain, with this user's sent
    /// state overlaid — what the contact form suggests while an address is typed.
    func companies(forDomain domain: String) async throws -> [Job] {
        var found = try await SupabaseAPI.companies(forDomain: domain)
        overlaySends(latestSendByContact, into: &found)
        return found.sortedByName()
    }

    // MARK: - Contact mutations

    /// Where a new contact goes: a company already in the catalog, or a new one
    /// created for them in the same step.
    enum ContactDestination {
        case existing(Job)
        case new(name: String)
    }

    /// Add a contact, and teach the catalog their mail domain.
    ///
    /// A work address the company doesn't list yet is added to its domains —
    /// unless another company already uses it, which is a question for the
    /// person (the form shows it), not something to settle silently. That's how
    /// the domain list fills in on its own, and why a later contact at the same
    /// domain gets pointed at the right company instead of starting a duplicate.
    func addContact(_ contact: Contact, to destination: ContactDestination) async {
        let domain = MailDomain.work(fromEmail: contact.email)
        await perform {
            switch destination {
            case .existing(let job):
                try await SupabaseAPI.addContact(companyID: job.id, contact: contact)
                guard let domain, !job.domains.contains(domain) else { return }
                let owners = try await SupabaseAPI.companies(forDomain: domain)
                guard owners.allSatisfy({ $0.id == job.id }) else { return }
                try await SupabaseAPI.setDomains(companyID: job.id, domains: job.domains + [domain])
            case .new(let name):
                let id = try await SupabaseAPI.addCompany(name: name, sector: nil,
                                                          domains: domain.map { [$0] } ?? [])
                try await SupabaseAPI.addContact(companyID: id, contact: contact)
            }
        }
    }

    /// Save an edited contact upstream, with a short window to undo it.
    func updateContact(_ contact: Contact) async {
        let previous = self.contact(id: contact.id)

        let saved = await perform { try await SupabaseAPI.updateContact(contact) }
        guard saved, let previous else { return }
        UndoCoordinator.shared.stage(message: "Contact details updated") { [weak self] in
            await self?.perform { try await SupabaseAPI.updateContact(previous) }
        }
    }

    /// Mark contacts valid or invalid in the shared catalog (upstream, for every
    /// user — a bounced address is bounced for everyone). Invalid ones can no
    /// longer be mailed, but they're kept, with their send
    /// history, so the company screen can still show who was ruled out and why.
    /// Fully reversible, which is why it's offered instead of deleting.
    @discardableResult
    func setValidity(_ ids: [Contact.ID], isValid: Bool) async -> Bool {
        guard !ids.isEmpty else { return false }
        return await perform { try await SupabaseAPI.setContactValidity(ids: ids, isValid: isValid) }
    }

    /// Delete a contact. Sent ones are kept as a record and can't be removed.
    func deleteContact(_ contact: Contact) async {
        await deleteContacts([contact])
    }

    /// Delete several contacts in one request and one reload, skipping any that
    /// have been mailed.
    func deleteContacts(_ contacts: [Contact]) async {
        let ids = contacts.filter { !$0.isSent }.map(\.id)
        guard !ids.isEmpty else { return }
        await perform { try await SupabaseAPI.deleteContacts(ids: ids) }
    }

    /// Append a send to this user's history for each contact. Does nothing
    /// when no Gmail is connected — you can't send without it.
    ///
    /// Deliberately not routed through `perform`: this is called by `MailQueue`
    /// every few mails of a background run, which can be minutes after the user
    /// left the send screen. Raising the app-wide "Saving…" block there would freeze
    /// whatever they'd moved on to, for a write they didn't ask for and aren't
    /// waiting on — the exact thing sending in the background is meant to avoid.
    /// The reload still happens, so the UI catches up; it just does it quietly.
    ///
    /// - Returns: whether the sends were recorded. A reload that fails afterwards
    ///   doesn't count against it — recording them again would duplicate them.
    @discardableResult
    func markContactsSent(_ records: [Contact.ID: SentMail]) async -> Bool {
        guard !records.isEmpty, let email = userEmail else { return false }
        do {
            try await SupabaseAPI.recordSends(userEmail: email, records: records, at: Date())
        } catch {
            report(error)
            return false
        }
        do {
            try await reloadAll()
        } catch {
            report(error)
        }
        return true
    }

    // MARK: - Hiring sources (shared, upstream)

    /// Fetch a company's sources. Quiet on failure: the company screen still
    /// shows everything else, and says the sources couldn't be loaded.
    func loadSources(companyID: String) async {
        loadingSources.insert(companyID)
        defer { loadingSources.remove(companyID) }
        do {
            sources[companyID] = try await SupabaseAPI.fetchSources(companyID: companyID)
        } catch {
            if !error.isCancellation && sources[companyID] == nil { sources[companyID] = [] }
        }
    }

    /// Mark sources valid or invalid, for every user, with a short window to
    /// undo it. An invalid source stops counting toward the stated package.
    func setSourceValidity(_ changed: [CompanySource], isValid: Bool) async {
        let ids = changed.map(\.id)
        guard let companyID = changed.first?.companyID, !ids.isEmpty else { return }
        let saved = await performOnSources(companyID) {
            try await SupabaseAPI.setSourceValidity(ids: ids, isValid: isValid)
        }
        guard saved else { return }
        let noun = ids.count == 1 ? "Source" : "\(ids.count) sources"
        UndoCoordinator.shared.stage(message: "\(noun) marked \(isValid ? "valid" : "invalid")") { [weak self] in
            await self?.performOnSources(companyID) {
                try await SupabaseAPI.setSourceValidity(ids: ids, isValid: !isValid)
            }
        }
    }

    /// Add a source, or save an edited one. Returns whether it landed.
    @discardableResult
    func saveSource(_ source: CompanySource) async -> Bool {
        await performOnSources(source.companyID) {
            if source.id.isEmpty {
                try await SupabaseAPI.addSource(source)
            } else {
                try await SupabaseAPI.updateSource(source)
            }
        }
    }

    /// Delete sources for good. Marking one invalid is the reversible way.
    func deleteSources(_ doomed: [CompanySource]) async {
        guard let companyID = doomed.first?.companyID else { return }
        await performOnSources(companyID) {
            try await SupabaseAPI.deleteSources(ids: doomed.map(\.id))
        }
    }

    /// Run a write to one company's sources, then refetch just those — not the
    /// whole catalog, which a source never changes.
    @discardableResult
    private func performOnSources(_ companyID: String, _ operation: () async throws -> Void) async -> Bool {
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await operation()
        } catch {
            report(error)
            return false
        }
        await loadSources(companyID: companyID)
        return true
    }

    // MARK: - Export

    /// Everything the database holds that this account can see: the shared
    /// catalog (companies, contacts, hiring sources) and this account's own
    /// rows (sends, templates, profile, Home's companies). Other people's
    /// sends and templates are theirs, and stay out.
    func exportSnapshot() async throws -> DataExport {
        guard let email = userEmail else { throw ExportError.signedOut }
        let mine = [URLQueryItem(name: "user_email", value: "eq.\(email)")]
        // One table after another: an export is a few seconds once, and the
        // rows are raw JSON objects, which can't be handed between tasks.
        let companies = try await SupabaseAPI.fetchRows("companies", order: "name")
        let contacts = try await SupabaseAPI.fetchRows("recruiters", order: "id")
        let sources = try await Self.optionalRows("company_sources", order: "id")
        let sends = try await SupabaseAPI.fetchRows("mail_sends", filters: mine, order: "sent_at.desc")
        let templates = try await SupabaseAPI.fetchRows("templates", filters: mine, order: "name")
        let profile = try await SupabaseAPI.fetchRows("profiles", filters: [URLQueryItem(name: "email", value: "eq.\(email)")],
                                                      order: "email")
        let tracked = try await SupabaseAPI.fetchRows("tracked_companies", filters: mine, order: "company_id")
        return DataExport(account: email, exportedAt: Date(), companies: companies, contacts: contacts,
                          sources: sources, sends: sends, templates: templates, profile: profile,
                          tracked: tracked)
    }

    /// A table that may not exist yet (its migration pending) reads as empty.
    private static func optionalRows(_ path: String, order: String) async throws -> [[String: Any]] {
        do {
            return try await SupabaseAPI.fetchRows(path, order: order)
        } catch SupabaseError.schemaOutOfDate {
            return []
        }
    }

    // MARK: - Helpers

    /// Fetch this user's tracked companies and the full catalog, overlay their
    /// sent records, and rebuild the Activity feed.
    private func reloadAll() async throws {
        guard let email = userEmail else {
            jobs = []; allCompanies = []; detachedCompanies = [:]; searchResults = []
            activity = []; sends = []; sources = [:]; scopeCounts = [:]; catalogScope = .all
            companyOffset = 0; hasMoreCompanies = true; scopePages = [:]
            return
        }

        // One-time per account: lift any pre-sync, on-device selection up to the
        // server so it isn't lost now that the server owns Home membership.
        if !hasMigrated(email) {
            let serverIDs = Set(try await SupabaseAPI.fetchTrackedIDs(userEmail: email))
            for id in (trackedByEmail[email] ?? []) where !serverIDs.contains(id) {
                try await SupabaseAPI.addTracked(userEmail: email, companyID: id)
            }
            markMigrated(email)
        }

        // Every read below is independent of the others, so they're all in
        // flight at once: a reload — which every write in the app ends with,
        // behind the "Saving…" veil — costs the slowest request rather than the
        // sum of six or more round trips.
        //
        // The catalog refetches as many rows as were already paged in, not just
        // the first page. Collapsing the list back to page one would yank the
        // user out of wherever they'd scrolled — and drop the company they were
        // editing out of memory.
        let pageLimit = max(companyOffset, SupabaseAPI.defaultPageSize)
        let query = searchQuery
        let previousSearch = searchResults
        async let tracked = SupabaseAPI.fetchTrackedCompanies(userEmail: email)
        let scope = catalogScope
        async let catalog = SupabaseAPI.fetchAllCompanies(limit: pageLimit, offset: 0, scope: scope)
        async let counts = Self.countScopes()
        async let history = Self.fetchHistory(userEmail: email)
        async let detached = Self.refetch(Array(detachedCompanies.keys))
        async let search: [Job] = query.isEmpty
            ? [] : ((try? await SupabaseAPI.searchCompanies(query: query)) ?? previousSearch)

        let companies = try await tracked
        let all = try await catalog
        let (sends, activity) = try await history
        // Detached companies the catalog pages now cover are dropped from the
        // side table; one that came back nil was deleted (e.g. merged away).
        let catalogIDs = Set(all.map(\.id))
        let refreshedDetached = (await detached).filter { !catalogIDs.contains($0.key) }
        let refreshedSearch = await search
        let refreshedCounts = await counts

        // Server is the source of truth for membership; mirror it into the cache.
        trackedByEmail[email] = companies.map(\.id)
        trackedFile.save(trackedByEmail)
        companyOffset = all.count
        hasMoreCompanies = all.count == pageLimit

        // Assign everything together at the end, so no screen ever renders a
        // half-reloaded mix of new companies and old sent state.
        jobs = companies
        allCompanies = all
        detachedCompanies = refreshedDetached
        searchResults = refreshedSearch
        if !refreshedCounts.isEmpty { scopeCounts = refreshedCounts }
        apply(sends: sends, activity: activity)
        warmScopes()
    }

    /// Fetch the first page of every scope not yet held, in the background, so
    /// the chips switch instantly. Best-effort: a scope that fails just loads
    /// when tapped.
    private func warmScopes() {
        let missing = CatalogScope.allCases.filter { $0 != catalogScope && scopePages[$0] == nil }
        guard !missing.isEmpty, !SupabaseAPI.fresherColumnsMissing else { return }
        Task {
            await withTaskGroup(of: (CatalogScope, [Job]?).self) { group in
                for scope in missing {
                    group.addTask {
                        (scope, try? await SupabaseAPI.fetchAllCompanies(limit: SupabaseAPI.defaultPageSize,
                                                                         offset: 0, scope: scope))
                    }
                }
                for await case let (scope, page?) in group where scopePages[scope] == nil {
                    scopePages[scope] = CatalogPage(companies: page, offset: page.count,
                                                    hasMore: page.count == SupabaseAPI.defaultPageSize)
                }
            }
        }
    }

    /// Every scope's count, all at once. Empty when the database has no
    /// fresher columns yet, or the counts fail — the chips just go without.
    private static func countScopes() async -> [CatalogScope: Int] {
        await withTaskGroup(of: (CatalogScope, Int?).self) { group in
            for scope in CatalogScope.allCases {
                group.addTask { (scope, try? await SupabaseAPI.countCompanies(scope: scope)) }
            }
            var counts: [CatalogScope: Int] = [:]
            for await case let (scope, count?) in group { counts[scope] = count }
            return counts
        }
    }

    /// List another slice of the catalog. The pages loaded so far belong to the
    /// old scope, so the list starts again from the top of the new one.
    ///
    /// A scope seen before (or warmed in the background) shows at once and is
    /// refreshed behind the scenes; one not held yet clears the list, so the
    /// screen shows its spinner rather than the old scope's rows under the new
    /// chip.
    func setScope(_ scope: CatalogScope) async {
        guard scope != catalogScope else { return }
        scopePages[catalogScope] = CatalogPage(companies: allCompanies, offset: companyOffset,
                                               hasMore: hasMoreCompanies)
        catalogScope = scope
        let held = scopePages[scope]
        if var held {
            overlaySends(latestSendByContact, into: &held.companies)
            allCompanies = held.companies
            companyOffset = held.offset
            hasMoreCompanies = held.hasMore
        } else {
            allCompanies = []
            companyOffset = 0
            hasMoreCompanies = true
            isLoadingMoreCompanies = true
        }
        defer { if held == nil { isLoadingMoreCompanies = false } }
        do {
            let limit = max(held?.offset ?? 0, SupabaseAPI.defaultPageSize)
            var page = try await SupabaseAPI.fetchAllCompanies(limit: limit, offset: 0, scope: scope)
            // A quicker tap on another chip already replaced this one.
            guard scope == catalogScope else { return }
            overlaySends(latestSendByContact, into: &page)
            allCompanies = page
            companyOffset = page.count
            hasMoreCompanies = page.count == limit
        } catch {
            guard scope == catalogScope, held == nil else { return }
            allCompanies = []
            companyOffset = 0
            hasMoreCompanies = false
            if case SupabaseError.schemaOutOfDate = error {
                errorMessage = "Filtering by fresher hiring needs a one-time database update. Run the fresher-hiring migration from the README in the Supabase SQL editor."
            } else {
                report(error)
            }
        }
    }

    /// Refresh only sent records and reply state, without re-downloading the entire
    /// shared companies catalog from Supabase.
    private func reloadSendsOnly() async throws {
        guard let email = userEmail else { return }
        let (sends, activity) = try await Self.fetchHistory(userEmail: email)
        apply(sends: sends, activity: activity)
    }

    /// The whole send history and the Activity feed built from it.
    private static func fetchHistory(userEmail: String) async throws -> ([MailSend], [ActivityEntry]) {
        let sends = try await SupabaseAPI.fetchSends(userEmail: userEmail, limit: 0)
        return (sends, try await SupabaseAPI.fetchActivity(sends: sends))
    }

    /// Fresh copies of companies held outside the catalog pages, fetched all at
    /// once. Best-effort: one that fails or no longer exists is left out.
    private static func refetch(_ ids: [String]) async -> [String: Job] {
        await withTaskGroup(of: Job?.self) { group in
            for id in ids {
                group.addTask { try? await SupabaseAPI.fetchCompany(id: id) }
            }
            var fresh: [String: Job] = [:]
            for await case let job? in group { fresh[job.id] = job }
            return fresh
        }
    }

    /// Install a fresh send history: overlay it onto every company held in
    /// memory, then rebuild everything derived from it.
    private func apply(sends: [MailSend], activity: [ActivityEntry]) {
        self.sends = sends
        let byContact = latestSendByContact
        overlaySends(byContact, into: &jobs)
        overlaySends(byContact, into: &allCompanies)
        overlaySends(byContact, into: &searchResults)
        detachedCompanies = detachedCompanies.mapValues { Self.overlaying(byContact, onto: $0) }
        // Activity is built from the send history (not the tracked list), so
        // removing a company from Home leaves its sent records here untouched, and
        // every send — including repeats to the same contact — is its own row.
        self.activity = activity.sorted { Self.newestFirst($0, $1) }
    }

    /// Look up, in the account's own mail, the tracked companies' contacts that
    /// have nothing better than an address to be greeted by. Each address is
    /// looked up once; what's found greets them from then on.
    func lookUpNames() async {
        let emails = jobs.flatMap(\.contacts).filter(\.needsNameLookup).map(\.email)
        await MailboxNames.shared.lookUp(emails, accepting: RecipientName.isPersonEntry)
    }

    private static func newestFirst(_ a: ActivityEntry, _ b: ActivityEntry) -> Bool {
        switch (a.date, b.date) {
        case let (l?, r?): return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.company.localizedCaseInsensitiveCompare(b.company) == .orderedAscending
        }
    }

    // MARK: - Catalog paging

    /// Load the next page of the shared catalog.
    func loadMoreCompanies() async {
        guard !isLoadingMoreCompanies, hasMoreCompanies, !isLoading else { return }
        isLoadingMoreCompanies = true
        defer { isLoadingMoreCompanies = false }

        do {
            let scope = catalogScope
            var page = try await SupabaseAPI.fetchAllCompanies(
                limit: SupabaseAPI.defaultPageSize,
                offset: companyOffset,
                scope: scope
            )
            // The scope changed while this page was on its way: it belongs to
            // a list that's gone.
            guard scope == catalogScope else { return }
            companyOffset += page.count
            hasMoreCompanies = page.count == SupabaseAPI.defaultPageSize
            guard !page.isEmpty else { return }

            overlaySends(latestSendByContact, into: &page)
            // Rows can shift across a page boundary when the catalog changes
            // between loads; never show one twice.
            let existingIDs = Set(allCompanies.map(\.id))
            allCompanies.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
            for company in page { detachedCompanies[company.id] = nil }
        } catch {
            report(error)
        }
    }

    /// This user's latest send per contact. Sends come newest-first, so the first
    /// row per contact is their latest.
    private var latestSendByContact: [String: MailSend] {
        Dictionary(sends.map { ($0.contactID, $0) }, uniquingKeysWith: { latest, _ in latest })
    }

    /// Every company held in memory, each once: the catalog pages, then Home's
    /// list, companies opened directly, and search hits.
    private var knownCompanies: [Job] {
        var seen = Set<String>()
        return (allCompanies + jobs + Array(detachedCompanies.values) + searchResults)
            .filter { seen.insert($0.id).inserted }
    }

    /// Overlay this user's per-contact sent state onto a set of companies.
    private func overlaySends(_ byContact: [String: MailSend], into companies: inout [Job]) {
        companies = companies.map { Self.overlaying(byContact, onto: $0) }
    }

    /// One company with this user's latest send to each of its contacts laid over it.
    private static func overlaying(_ byContact: [String: MailSend], onto company: Job) -> Job {
        var company = company
        for index in company.contacts.indices {
            guard let send = byContact[company.contacts[index].id] else { continue }
            company.contacts[index].isSent = true
            company.contacts[index].sentAt = send.sentAt
            company.contacts[index].sentSubject = send.subject
            company.contacts[index].sentBody = send.body
            company.contacts[index].repliedAt = send.repliedAt
            company.contacts[index].replyFrom = send.replyFrom
            company.contacts[index].replySnippet = send.replySnippet
        }
        return company
    }

    /// Where each contact's mail was addressed, for recovering the thread id of
    /// a send made before the app captured one.
    var emailByContact: [String: String] {
        var result: [String: String] = [:]
        for company in knownCompanies {
            for contact in company.contacts where !contact.email.isEmpty {
                result[contact.id] = contact.email
            }
        }
        for entry in activity where !entry.contact.email.isEmpty {
            result[entry.contact.id] = entry.contact.email
        }
        return result
    }

    /// Run a write, then refresh from the database so local state stays in sync.
    /// `inFlight` drives the app-wide "Saving…" state for the whole round-trip.
    /// Returns whether the write itself succeeded (a failed reload afterwards is
    /// reported, but doesn't un-happen the write).
    @discardableResult
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await operation()
        } catch {
            report(error)
            return false
        }
        do {
            try await reloadAll()
        } catch {
            report(error)
        }
        return true
    }

    /// Surface an error, ignoring cancellations from interrupted view reloads.
    private func report(_ error: Error) {
        if !error.isCancellation { errorMessage = error.localizedDescription }
    }
}
