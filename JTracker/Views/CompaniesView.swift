import SwiftUI

/// The Companies tab: the full shared catalog. This is where companies are added,
/// edited, deleted (all upstream, for every user), and tracked onto your Home.
/// By default only companies with at least one contact are shown; a "Show empty"
/// toggle reveals the rest.
struct CompaniesView: View {
    @Environment(JobStore.self) private var jobStore

    @State private var searchText = ""
    @State private var showEmpty = false
    @State private var selection = ListSelection<String>()
    @State private var confirmingDelete = false
    @State private var pendingDelete: Job?
    @State private var isAdding = false
    @State private var isAddingContact = false
    @State private var sendingTo: SendTarget?
    @Namespace private var zoom
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
    private var filtered: [Job] {
        guard query.isEmpty else {
            return .matching(query, in: jobStore.allCompanies, jobStore.searchResults)
        }
        return showEmpty ? jobStore.allCompanies : jobStore.allCompanies.filter { !$0.contacts.isEmpty }
    }

    var body: some View {
        // Filtered once per render: the rows, the empty check and the paging
        // trigger all read the same array instead of each re-filtering the catalog.
        let rows = filtered
        return NavigationStack(path: $path) {
            Group {
                if jobStore.allCompanies.isEmpty {
                    if jobStore.isLoading {
                        LoadingState()
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
                        Section {
                            companyRows(rows)
                            if jobStore.isLoadingMoreCompanies || jobStore.isSearchingServer {
                                LoadingRow()
                            }
                        }
                        .cardRow()
                    }
                    .cardList()
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
                // The card the user tapped grows into the company screen, and
                // shrinks back into its place on the way out.
                JobDetailView(jobID: companyID)
                    .navigationTransition(.zoom(sourceID: companyID, in: zoom))
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
                CompanyFormView(title: "New Company", confirmLabel: "Add") { name, sector, domains in
                    // A brand-new company has no contacts yet, so reveal empty
                    // companies — otherwise the add would seem to do nothing.
                    showEmpty = true
                    Task {
                        await jobStore.createCompany(
                            name: name,
                            sector: sector.isEmpty ? nil : sector,
                            domains: domains
                        )
                    }
                }
            }
            .addContactSheet(isPresented: $isAddingContact)
            .sendChooser(for: $sendingTo) { selection.exit() }
            .companyEditor(for: $editingCompany)
            .undoBanner()
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
        Toggle(isOn: $showEmpty) {
            Label("Show empty companies", systemImage: "tray")
        }
    }

    /// The row whose appearance fetches the next page: ten from the end.
    private func prefetchID(in companies: [Job]) -> String? {
        companies.dropLast(10).last?.id ?? companies.first?.id
    }

    @ViewBuilder
    private func companyRows(_ companies: [Job]) -> some View {
        ForEach(companies) { company in
            let tracked = jobStore.isTracked(company.id)
            CompanyRow(job: company, isTracked: tracked)
                .matchedTransitionSource(id: company.id, in: zoom)
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
                if tracked {
                    Button {
                        Haptics.tap()
                        jobStore.untrack(companyID: company.id)
                    } label: {
                        Label("Untrack", systemImage: "pin.slash")
                    }
                    .tint(.slate)
                } else {
                    Button {
                        // Pinning something to Home is the one constructive swipe
                        // on this screen, so it lands firmer than untracking does.
                        Haptics.press()
                        jobStore.track(companyID: company.id)
                    } label: {
                        Label("Track", systemImage: "pin")
                    }
                    .tint(.olive)
                }
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
            Text(query.isEmpty
                 ? "No companies with contacts. Turn on “Show empty companies” to see the rest."
                 : "No company, sector or contact matches “\(query)”.")
        }
    }
}

/// A company card in the Companies list: monogram, name, sector, a pin when
/// tracked, a fixed-size contacts-count pill that never truncates, and the same
/// outreach chips Home's cards carry.
///
/// Always three lines, whatever the company has on file — a missing sector says
/// so rather than collapsing the line — so every card in the catalog is the same
/// height and the list scrolls as an even column.
private struct CompanyRow: View {
    let job: Job
    let isTracked: Bool

    private var sector: String? {
        guard let sector = job.sector, !sector.isEmpty else { return nil }
        return sector
    }

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(company: job.company)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(job.company)
                        .font(.headline)
                        .lineLimit(1)
                    if isTracked {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            // The pin springs in the moment a swipe tracks the
                            // company, on the row the swipe happened on.
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                Text(sector ?? "No sector")
                    .font(.caption)
                    .foregroundStyle(sector == nil ? Color.inkFaint : Color.inkMuted)
                    .lineLimit(1)
                // Own line, for the same reason as Home's card: a long sector name
                // beside a fixed-width chip overflowed the row on a narrow phone.
                OutreachChips(job: job)
                    .padding(.top, 1)
            }
            // Fills the row. Beside a Spacer the HStack split the spare room
            // between the two, and "1DigitalStack" truncated to "1Digital…"
            // next to half a row of empty card.
            .frame(maxWidth: .infinity, alignment: .leading)

            countPill

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.inkFaint)
        }
        .padding(12)
        .panel()
        .animation(Theme.Motion.pop, value: isTracked)
    }

    /// The contact count as a compact capsule. `fixedSize` keeps it at its
    /// intrinsic width so it can never be squeezed or overflow — the name
    /// truncates instead.
    private var countPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill")
            Text("\(job.contacts.count)")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.inkMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.inkMuted.opacity(0.15), in: Capsule())
        .fixedSize()
    }
}
