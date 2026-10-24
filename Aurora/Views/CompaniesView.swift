import SwiftUI

/// The Companies tab: the full shared catalog. This is where companies are added,
/// edited, deleted (all upstream, for every user), and tracked onto your Home.
/// By default only companies with at least one contact are shown; the filter
/// menu in the top bar reveals the rest, or narrows the list to fresher hiring.
struct CompaniesView: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var showEmpty = false
    @State private var selection = ListSelection<String>()
    @State private var confirmingDelete = false
    @State private var pendingDelete: Job?
    @State private var isAdding = false
    @State private var isAddingContact = false
    @State private var sendingTo: SendTarget?
    @State private var editingCompany: Job?
    /// Rows push through this rather than through `NavigationLink`, so the card
    /// can carry its own chevron instead of the system drawing one outside it.
    @State private var path = NavigationPath()

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Companies to show: catalog filtered by the "show empty" toggle and the
    /// search text. Already name-sorted by the store.
    ///
    /// A search overrides "show empty": having typed a name, a company that
    /// matches it but has no contacts yet is a result, not a row to hide — and
    /// hiding it is indistinguishable from the company not existing, which is the
    /// question the search was asked to answer.
    ///
    /// Searching covers the loaded pages *and* the server's matches, so a company
    /// on a page not yet scrolled to is still found.
    ///
    /// A fresher scope lists every company in it, contacts or not, for the same
    /// reason: having asked for companies that hire freshers, one with nobody on
    /// file yet is still an answer — and its careers page is what's wanted.
    private var filtered: [Job] {
        let scope = jobStore.catalogScope
        guard query.isEmpty else {
            // Server hits come from the whole catalog; the scope still applies.
            return [Job].matching(query, in: jobStore.allCompanies, jobStore.searchResults).filter(scope.includes)
        }
        return showEmpty || scope != .all ? jobStore.allCompanies : jobStore.allCompanies.filter { !$0.contacts.isEmpty }
    }

    /// The fresher scopes are offered once the database can filter by them.
    private var showsScopes: Bool { !SupabaseAPI.fresherColumnsMissing }

    /// Anything other than the plain catalog: the filter glyph fills in, and
    /// the line over the list offers to clear it.
    private var isFiltering: Bool { jobStore.catalogScope != .all || showEmpty }

    var body: some View {
        // Filtered once per render: the rows, the empty check and the paging
        // trigger all read the same array instead of each re-filtering the catalog.
        let rows = filtered
        return NavigationStack(path: $path) {
            Group {
                if jobStore.allCompanies.isEmpty {
                    if jobStore.isLoading || jobStore.isLoadingMoreCompanies {
                        LoadingState()
                    } else if jobStore.catalogScope != .all {
                        emptyScopeState
                    } else {
                        emptyState
                    }
                } else if rows.isEmpty {
                    if jobStore.isSearchingServer || (query.isEmpty && jobStore.hasMoreCompanies) {
                        LoadingState(label: query.isEmpty ? nil : "Searching companies…")
                            // Every loaded company can be empty while later pages
                            // aren't: with no last row to scroll to, nothing else
                            // would ever ask for the next page.
                            .task(id: jobStore.allCompanies.count) {
                                if query.isEmpty { await jobStore.loadMoreCompanies() }
                            }
                    } else {
                        noMatchesState
                    }
                } else {
                    List(selection: $selection.ids) {
                        // Margins go on each row (see `cardRow`), not on the
                        // section: a row rebuilt in place — a company whose
                        // chips update after a reply sync — lost the section's
                        // and spread to the screen edges.
                        Section {
                            // What's listed, as the list's first row: it
                            // scrolls with the content, so the title, search
                            // field and bars behave as on every other tab.
                            if !selection.isSelecting {
                                statusLine(resultCount: rows.count)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets())
                            }
                            companyRows(rows)
                            if jobStore.isLoadingMoreCompanies || jobStore.isSearchingServer {
                                LoadingRow()
                                    .cardRow()
                            }
                        }
                    }
                    .cardList()
                    // A new scope is a new list: start at its top, not wherever
                    // the last one was scrolled to.
                    .id(jobStore.catalogScope)
                    .listRows(selection) { path.append($0) } menu: { rowMenu($0) }
                    .refreshable { await jobStore.load() }
                    // Typing re-cuts the list on every keystroke; the rows just
                    // change rather than springing once per character. (A row's
                    // pin animates on the row itself — a list-wide spring on
                    // tracking re-laid every cell for one icon.)
                    .animation(nil, value: query)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .paperScreen()
            .navigationTitle("Companies")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { companyID in
                // The system push, not a zoom out of the card: on iOS 27 a
                // swipe back from a zoom left the bar behind and the screen
                // ignoring touches for a few seconds.
                JobDetailView(jobID: companyID)
            }
            .searchable(text: $searchText, isPresented: $isSearchPresented,
                        prompt: "Search companies, sectors, people")
            // Contacts are matched on the phone: have them ready by the time
            // the first letter is typed.
            .onChange(of: isSearchPresented) { _, presented in
                if presented { jobStore.prepareSearch() }
            }
            // Cancelled and restarted per keystroke, which is what debounces it.
            .task(id: query) { await jobStore.searchCompanies(query: query) }
            .topBarActions(
                TopBarPrimary(title: "Add Company", systemImage: "plus") { isAdding = true },
                isHidden: selection.isSelecting,
                isFiltering: isFiltering
            ) { filterMenu } more: { menu }
            .selectionActions(
                selection,
                all: rows.map(\.id),
                noun: SelectionNoun(singular: "company", plural: "companies"),
                confirmingDelete: $confirmingDelete,
                deleteMessage: "This permanently deletes the selected companies and your contacts at them, for every user. A company with other people's contacts is kept. This can't be undone.",
                sendableCount: selectedCompanies.reduce(0) { $0 + $1.validContacts.count },
                onSend: { sendingTo = SendTarget(companies: selectedCompanies) },
                bulkAction: trackAction,
                onDelete: deleteSelected
            )
            .uniformDeleteAlert(
                item: $pendingDelete,
                title: { "Delete “\($0.company)”?" },
                message: "This permanently deletes the company and your contacts at it, for every user. A company with other people's contacts is kept. This can't be undone."
            ) { company in
                Task { await jobStore.deleteCompanies([company.id]) }
            }
            .sheet(isPresented: $isAdding) {
                CompanyFormView(title: "New Company", confirmLabel: "Add") { details in
                    // A brand-new company has no contacts yet, so reveal empty
                    // companies — otherwise the add would seem to do nothing.
                    showEmpty = true
                    Task { await jobStore.createCompany(details) }
                }
            }
            .addContactSheet(isPresented: $isAddingContact)
            .sendChooser(for: $sendingTo) { selection.exit() }
            .companyEditor(for: $editingCompany)
            .undoBanner()
        }
    }

    /// A line saying what's listed, with a way back to the whole catalog
    /// beside it while a filter is on.
    private func statusLine(resultCount: Int) -> some View {
        // One line beside the button, or stacked at large text sizes, where
        // "127 tracked on Home" was cut to "127 t…".
        let stacked = typeSize.isAccessibilitySize
        return (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 10))) {
            Group {
                if !query.isEmpty {
                    Text(resultCount == 1 ? "1 match" : "\(resultCount.formatted()) matches")
                } else if jobStore.catalogScope != .all {
                    let scope = jobStore.catalogScope
                    HStack(spacing: 6) {
                        Image(systemName: scope.systemImage)
                        Text("\(scope.title) · \((jobStore.scopeCounts[scope] ?? resultCount).formatted())")
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "pin.fill")
                        Text("\(jobStore.jobs.count.formatted()) tracked on Home")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.inkMuted)
            .lineLimit(2)
            .frame(maxWidth: stacked ? nil : .infinity, alignment: .leading)

            if isFiltering {
                // Plain text, not a bordered button: its chrome made this row
                // taller than the line it sits beside.
                Button(action: clearFilters) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear Filter")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.clay)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearFilters() {
        Haptics.select()
        withAnimation(Theme.Motion.snappy) { showEmpty = false }
        if jobStore.catalogScope != .all {
            Task { await jobStore.setScope(.all) }
        }
    }

    /// The bar's filter menu: the fresher scopes, each with how many companies
    /// it holds, then whether companies with nobody on file are listed.
    @ViewBuilder
    private var filterMenu: some View {
        if showsScopes {
            // Toggles rather than an inline picker: a menu drops a picker
            // item's subtitle, and the count is the point of the subtitle.
            Section("Show") {
                ForEach(CatalogScope.allCases) { scope in
                    Toggle(isOn: Binding(get: { jobStore.catalogScope == scope },
                                         set: { on in
                                             guard on else { return }
                                             Haptics.select()
                                             Task { await jobStore.setScope(scope) }
                                         })) {
                        Label(scope.title, systemImage: scope.systemImage)
                        if let count = jobStore.scopeCounts[scope] {
                            Text(count == 1 ? "1 company" : "\(count.formatted()) companies")
                        }
                    }
                }
            }
        }
        Section {
            // A scope already lists its empty companies (see `filtered`).
            Toggle(isOn: Binding(get: { showEmpty },
                                 set: { on in withAnimation(Theme.Motion.snappy) { showEmpty = on } })) {
                Label("Show Empty Companies", systemImage: "tray")
            }
            .disabled(jobStore.catalogScope != .all)
        }
    }

    /// The card's pin button and the leading swipe: onto Home, or off it.
    private func toggleTracking(_ company: Job) {
        if jobStore.isTracked(company.id) {
            Haptics.tap()
            jobStore.untrack(companyID: company.id)
        } else {
            // Pinning something to Home is the one constructive act on this
            // screen, so it lands firmer than untracking does.
            Haptics.press()
            jobStore.track(companyID: company.id)
        }
    }

    /// Adding a company is the bar's own `+` and filtering its own menu; this
    /// has the rest.
    @ViewBuilder
    private var menu: some View {
        Button { isAddingContact = true } label: {
            Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
        }
        Button { selection.enter() } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        .disabled(jobStore.allCompanies.isEmpty)
    }

    /// The row whose appearance fetches the next page: ten from the end.
    private func prefetchID(in companies: [Job]) -> String? {
        companies.dropLast(10).last?.id ?? companies.first?.id
    }

    @ViewBuilder
    private func companyRows(_ companies: [Job]) -> some View {
        ForEach(companies) { company in
            let tracked = jobStore.isTracked(company.id)
            CompanyCard(job: company, isTracked: tracked,
                        // While selecting, a tap anywhere on the card ticks it.
                        onToggleTrack: selection.isSelecting ? nil : { toggleTracking(company) },
                        matchedName: company.otherName(matching: query))
                .cardRow()
                // Ask for the next 50 while ten rows are still to come, so the
                // page lands before the list runs out rather than after.
                .onAppear {
                    if query.isEmpty, company.id == prefetchID(in: companies) {
                        Task { await jobStore.loadMoreCompanies() }
                    }
                }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    // A warning, not a knock: this swipe opens a dialog that
                    // deletes for every user, and it should feel like a stop.
                    Haptics.warning()
                    pendingDelete = company
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                // Track/Untrack is declared first so a full ("extreme") swipe
                // triggers it; Edit sits behind it.
                Button { toggleTracking(company) } label: {
                    Label(tracked ? "Untrack" : "Track", systemImage: tracked ? "pin.slash" : "pin")
                }
                .tint(tracked ? .slate : .olive)
                Button {
                    Haptics.tap()
                    editingCompany = company
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.clay)
            }
        }
    }

    /// A held row's menu — or, while selecting, the menu for everything ticked.
    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        let companies = jobStore.allCompanies.filter { ids.contains($0.id) }
        if !companies.isEmpty {
            let allTracked = companies.allSatisfy { jobStore.isTracked($0.id) }
            if allTracked {
                Button {
                    Haptics.tap()
                    for company in companies { jobStore.untrack(companyID: company.id) }
                } label: {
                    Label("Untrack", systemImage: "pin.slash")
                }
            } else {
                Button {
                    let untracked = companies.filter { !jobStore.isTracked($0.id) }
                    Haptics.cascade(untracked.count)
                    jobStore.trackCompanies(untracked.map(\.id))
                } label: {
                    Label("Track", systemImage: "pin")
                }
            }
            if companies.count == 1, let company = companies.first {
                Button { editingCompany = company } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            Button {
                sendingTo = SendTarget(companies: companies)
            } label: {
                Label("Send…", systemImage: "paperplane")
            }
            .disabled(companies.allSatisfy { $0.validContacts.isEmpty })
            if !selection.isSelecting {
                Button { selection.begin(with: ids) } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                Haptics.warning()
                if companies.count == 1 {
                    pendingDelete = companies.first
                } else {
                    // Only a selection offers more than one row to a menu, so
                    // this is the bar's own delete, with its own dialog.
                    confirmingDelete = true
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var selectedCompanies: [Job] {
        jobStore.allCompanies.filter { selection.contains($0.id) }
    }

    /// One slot that flips meaning: once everything selected is already tracked,
    /// "Track" is a no-op, so the button becomes the useful inverse instead of
    /// leaving tracked companies with no bulk action at all.
    private var trackAction: SelectionBulkAction {
        let selected = selectedCompanies
        let allTracked = !selected.isEmpty && selected.allSatisfy { jobStore.isTracked($0.id) }
        return SelectionBulkAction(
            title: allTracked ? "Untrack" : "Track",
            systemImage: allTracked ? "pin.slash.fill" : "pin.fill"
        ) {
            if allTracked {
                for company in selected { jobStore.untrack(companyID: company.id) }
                Haptics.tap()
            } else {
                jobStore.trackCompanies(Array(selection.ids))
                // One beat per company, capped — a bulk track should feel like
                // more than a single one did.
                Haptics.cascade(selection.count)
            }
            selection.exit()
        }
    }

    private func deleteSelected() {
        let ids = Array(selection.ids)
        Haptics.thud()
        selection.exit()
        Task { await jobStore.deleteCompanies(ids) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Companies Yet", systemImage: "building.2")
        } description: {
            Text("Add a company to the shared catalog.")
        } actions: {
            Button {
                isAdding = true
            } label: {
                Label("Add Company", systemImage: "plus")
            }
            .primaryButton()
        }
    }

    private var noMatchesState: some View {
        ContentUnavailableView {
            Label("No Companies", systemImage: "magnifyingglass")
        } description: {
            if !query.isEmpty {
                Text(jobStore.catalogScope == .all
                     ? "No company, sector or contact matches “\(query)”."
                     : "No company in “\(jobStore.catalogScope.title)” matches “\(query)”.")
            } else {
                Text("No companies with contacts. Turn on “Show Empty Companies” in the filter menu to see the rest.")
            }
        } actions: {
            if !query.isEmpty && jobStore.catalogScope != .all {
                Button("Search All Companies") {
                    Task { await jobStore.setScope(.all) }
                }
                .secondaryButton()
            }
        }
    }

    /// A fresher scope with nothing in it.
    private var emptyScopeState: some View {
        ContentUnavailableView {
            Label("Nothing in “\(jobStore.catalogScope.title)”", systemImage: jobStore.catalogScope.systemImage)
        } description: {
            Text("No company in the catalog is in this group yet.")
        } actions: {
            Button("Show All Companies") {
                Task { await jobStore.setScope(.all) }
            }
            .secondaryButton()
        }
    }
}
