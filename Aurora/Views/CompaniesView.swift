import SwiftUI

/// The Companies tab: the full shared catalog. This is where companies are added,
/// edited, deleted (all upstream, for every user), and tracked onto your Home.
/// By default only companies with at least one contact are shown; a "Show empty"
/// toggle reveals the rest.
struct CompaniesView: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var searchText = ""
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

    /// The filter chips show once the database can filter by fresher hiring.
    private var showsScopes: Bool { !SupabaseAPI.fresherColumnsMissing }

    var body: some View {
        // Filtered once per render: the rows, the empty check and the paging
        // trigger all read the same array instead of each re-filtering the catalog.
        let rows = filtered
        let showsList = !jobStore.allCompanies.isEmpty && !rows.isEmpty
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
                            // The filters are the list's first row, like
                            // Activity's lane selector: they scroll with the
                            // content, so the title, search field and bars
                            // behave as on every other tab. The ⋯ menu has the
                            // same choices once they're scrolled away.
                            if !selection.isSelecting {
                                filterHeader(resultCount: rows.count)
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
            // An empty or loading screen doesn't scroll, so its header can sit
            // over it — a scope is still a tap away from an empty result.
            .safeAreaInset(edge: .top, spacing: 0) {
                if !showsList && !selection.isSelecting {
                    filterHeader(resultCount: 0)
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
            .searchable(text: $searchText, prompt: "Search companies, sectors, people")
            // Cancelled and restarted per keystroke, which is what debounces it.
            .task(id: query) { await jobStore.searchCompanies(query: query) }
            .topBarActions(
                TopBarPrimary(title: "Add Company", systemImage: "plus") { isAdding = true },
                isHidden: selection.isSelecting
            ) { menu }
            .selectionActions(
                selection,
                all: rows.map(\.id),
                noun: SelectionNoun(singular: "company", plural: "companies"),
                confirmingDelete: $confirmingDelete,
                deleteMessage: "This permanently deletes the selected companies — and their contacts — from the shared database, for every user. This can't be undone.",
                sendableCount: selectedCompanies.reduce(0) { $0 + $1.validContacts.count },
                onSend: { sendingTo = SendTarget(companies: selectedCompanies) },
                bulkAction: trackAction,
                onDelete: deleteSelected
            )
            .uniformDeleteAlert(
                item: $pendingDelete,
                title: { "Delete “\($0.company)”?" },
                message: "This permanently deletes the company and its contacts from the shared database, for every user. This can't be undone."
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

    /// The filter chips over a line saying what's listed, with the empty
    /// companies' switch beside it rather than only in the ⋯ menu.
    private func filterHeader(resultCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsScopes {
                ScopeBar(selection: jobStore.catalogScope, counts: jobStore.scopeCounts) { scope in
                    Haptics.select()
                    Task { await jobStore.setScope(scope) }
                }
            }
            // One line beside the switch, or stacked at large text sizes, where
            // "127 tracked on Home" was cut to "127 t…".
            let stacked = typeSize.isAccessibilitySize
            (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                     : AnyLayout(HStackLayout(spacing: 10))) {
                Group {
                    if !query.isEmpty {
                        Text(resultCount == 1 ? "1 match" : "\(resultCount.formatted()) matches")
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

                if query.isEmpty && jobStore.catalogScope == .all {
                    // Plain text, not a bordered toggle button: its chrome made
                    // this row taller than the line it sits beside.
                    Button {
                        Haptics.select()
                        withAnimation(Theme.Motion.snappy) { showEmpty.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showEmpty ? "tray.full.fill" : "tray")
                            Text("Show empty")
                        }
                        .font(.caption.weight(.semibold))
                            .foregroundStyle(showEmpty ? Color.clay : Color.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityAddTraits(showEmpty ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, showsScopes ? 0 : 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Adding a company is the bar's own `+`; the menu has the rest.
    @ViewBuilder
    private var menu: some View {
        Button { isAddingContact = true } label: {
            Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
        }
        Button { selection.enter() } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        .disabled(jobStore.allCompanies.isEmpty)
        Divider()
        if showsScopes {
            // The chips' choices again, for VoiceOver and Switch Control users
            // who'd rather not hunt along a scrolling row.
            Picker(selection: Binding(get: { jobStore.catalogScope },
                                      set: { scope in Task { await jobStore.setScope(scope) } })) {
                ForEach(CatalogScope.allCases) { scope in
                    Label(scope.title, systemImage: scope.systemImage).tag(scope)
                }
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
            }
            .pickerStyle(.menu)
        }
        Toggle(isOn: $showEmpty) {
            Label("Show empty companies", systemImage: "tray")
        }
        .disabled(jobStore.catalogScope != .all)
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
                        onToggleTrack: selection.isSelecting ? nil : { toggleTracking(company) })
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
                Text("No companies with contacts. Turn on “Show empty” to see the rest.")
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

/// The row of filter chips over the catalog: All, then the fresher-hiring
/// scopes, each with how many companies it holds.
private struct ScopeBar: View {
    let selection: CatalogScope
    let counts: [CatalogScope: Int]
    let onSelect: (CatalogScope) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CatalogScope.allCases) { scope in
                        chip(scope)
                            .id(scope)
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, 8)
            }
            .onChange(of: selection) { _, scope in
                withAnimation(Theme.Motion.snappy) { proxy.scrollTo(scope, anchor: .center) }
            }
        }
    }

    private func chip(_ scope: CatalogScope) -> some View {
        let isOn = scope == selection
        let count = counts[scope]
        return Button {
            guard !isOn else { return }
            onSelect(scope)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: scope.systemImage)
                    .font(.caption2.weight(.semibold))
                Text(scope.title)
                    .font(.footnote.weight(.semibold))
                if let count {
                    Text(count.formatted())
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? Color.white.opacity(0.8) : Color.inkFaint)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(isOn ? Color.white : Color.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isOn {
                    Capsule().fill(Color.clay)
                } else {
                    Capsule().fill(Color.paperRaised)
                        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(BouncyPress(scale: 0.94))
        .animation(Theme.Motion.snappy, value: isOn)
        .accessibilityLabel(count.map { "\(scope.title), \($0)" } ?? scope.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
