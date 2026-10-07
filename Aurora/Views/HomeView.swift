import SwiftUI

/// The Home tab: the companies you're tracking, each carrying its own
/// reply/waiting state, so "did anyone answer?" is legible without leaving the
/// screen. Sending is done from here directly — select companies (or swipe one)
/// and the send chooser opens on them.
///
/// Rows are `List` rows with cleared backgrounds rather than a `ScrollView` of
/// cards, so the list's own interactions — tap, hold for the menu, swipe to
/// untrack, two-finger drag to select — keep working while the cards get their
/// own shape.
struct HomeView: View {
    @Environment(JobStore.self) private var jobStore

    /// Drives navigation to a tracked company's detail. Rows open through the
    /// list's primary action (not `NavigationLink`) so the card fills the row
    /// without the system's chevron and inset.
    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var isAddingContact = false
    /// The companies a Send from the selection bar is choosing recipients at.
    @State private var sendingTo: SendTarget?
    @Namespace private var zoom
    @State private var selection = ListSelection<String>()

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !query.isEmpty }

    /// Tracked companies narrowed by the search field. A company matches on its own
    /// name or sector *and* on the people inside it: Home is where you go to find
    /// the company you mailed someone at, and by then the name you remember is
    /// often theirs rather than the company's.
    private var filteredJobs: [Job] {
        guard isSearching else { return jobStore.jobs }
        return jobStore.jobs.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if jobStore.isLoading && jobStore.jobs.isEmpty {
                    LoadingState()
                } else {
                    List(selection: $selection.ids) {
                        trackingSection
                    }
                    .cardList()
                    .listRows(selection) { path.append($0) } menu: { rowMenu($0) }
                    .refreshable { await jobStore.load() }
                    .scrollDismissesKeyboard(.immediately)
                    // Rows sliding in and out is the whole feedback for tracking
                    // and untracking — the list is where the change lands. Not a
                    // bouncy spring: the list moves its cells with it, and an
                    // overshoot there reads as cards colliding.
                    .animation(Theme.Motion.snappy, value: jobStore.jobs.map(\.id))
                    // Typing re-cuts the list on every keystroke, and a spring per
                    // character turns a search into a shuffle. The rows just change.
                    .animation(nil, value: query)
                    .overlay {
                        if isSearching && filteredJobs.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .paperScreen()
                        }
                    }
                }
            }
            .paperScreen()
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search tracked companies and people")
            .navigationDestination(for: String.self) { companyID in
                // The card the user tapped grows into the company screen, and
                // shrinks back into its place on the way out.
                JobDetailView(jobID: companyID)
                    .navigationTransition(.zoom(sourceID: companyID, in: zoom))
            }
            .topBarActions(
                TopBarPrimary(title: "Add Contact", systemImage: "plus") { isAddingContact = true },
                isHidden: selection.isSelecting
            ) {
                Button { selection.enter() } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(jobStore.jobs.isEmpty)
            }
            .selectionActions(
                selection,
                all: filteredJobs.map(\.id),
                noun: SelectionNoun(singular: "company", plural: "companies"),
                sendableCount: selectedCompanies.reduce(0) { $0 + $1.validContacts.count },
                onSend: { sendingTo = SendTarget(companies: selectedCompanies) },
                bulkAction: SelectionBulkAction(
                    title: "Untrack",
                    systemImage: "pin.slash.fill"
                ) {
                    let selected = jobStore.jobs.filter { selection.contains($0.id) }
                    selection.exit()
                    remove(selected)
                }
            )
            .undoBanner()
            .addContactSheet(isPresented: $isAddingContact)
            .sendChooser(for: $sendingTo) { selection.exit() }
        }
    }

    private var selectedCompanies: [Job] {
        jobStore.jobs.filter { selection.contains($0.id) }
    }

    // MARK: - Tracking

    @ViewBuilder
    private var trackingSection: some View {
        Section {
            if jobStore.jobs.isEmpty {
                InlineEmptyState(title: "Nothing tracked yet",
                                 systemImage: "pin",
                                 message: "Swipe right on a company in Companies, or open one and choose Track on Home.")
                    .cardRow()
            } else {
                ForEach(filteredJobs) { job in
                    TrackingCard(job: job)
                        .matchedTransitionSource(id: job.id, in: zoom)
                        .cardRow()
                        .swipeActions(edge: .trailing) { untrackButton(job) }
                        // Both edges used to untrack. The leading one now does
                        // the other thing a tracked company is for, as Mail's
                        // leading swipe is the constructive one.
                        .swipeActions(edge: .leading) {
                            Button {
                                Haptics.press()
                                sendingTo = SendTarget(companies: [job])
                            } label: {
                                Label("Send", systemImage: "paperplane")
                            }
                            .tint(.clay)
                            .disabled(job.validContacts.isEmpty)
                        }
                }
            }
        } header: {
            SectionLabel(title: "Tracking", systemImage: "pin.fill",
                         count: jobStore.jobs.isEmpty ? nil : filteredJobs.count)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, 2)
                .listRowInsets(EdgeInsets())
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// A held row's menu — or, while selecting, the menu for everything ticked.
    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        let jobs = jobStore.jobs.filter { ids.contains($0.id) }
        if !jobs.isEmpty {
            Button {
                sendingTo = SendTarget(companies: jobs)
            } label: {
                Label("Send…", systemImage: "paperplane")
            }
            .disabled(jobs.allSatisfy { $0.validContacts.isEmpty })
            if !selection.isSelecting {
                Button { selection.begin(with: ids) } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                selection.ids.subtract(ids)
                remove(jobs)
            } label: {
                Label(jobs.count == 1 ? "Untrack" : "Untrack \(jobs.count)", systemImage: "pin.slash")
            }
        }
    }

    private func untrackButton(_ job: Job) -> some View {
        Button(role: .destructive) {
            remove([job])
        } label: {
            Label("Untrack", systemImage: "pin.slash")
        }
    }

    // MARK: - Untrack + Undo

    /// Untrack companies right away and offer a brief Undo. Untracking is
    /// reversible (it doesn't touch the shared catalog), so there's no confirm.
    ///
    /// The Undo is the app's one shared banner rather than a capsule of Home's
    /// own — the same object, in the same place, that every other reversible
    /// edit in the app offers.
    private func remove(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        // The flat knock, not the light one: this is the destructive edge of the
        // swipe, and it should feel unlike selecting the row it just removed.
        Haptics.thud()
        for job in jobs { jobStore.deleteJob(job) }
        let store = jobStore
        UndoCoordinator.shared.stage(
            message: jobs.count == 1 ? "Untracked \(jobs[0].company)" : "Untracked \(jobs.count) companies",
            duration: 6
        ) {
            for job in jobs { store.restoreJob(job) }
        }
    }
}

// MARK: - Tracking card

/// A tracked company, carrying its own outreach state: how many people, how many
/// answered, and how long the rest have been quiet.
///
/// Always the same three lines — name, head count, status — so every card in the
/// list is the same height whatever state its company is in.
private struct TrackingCard: View {
    let job: Job

    private var subtitle: String {
        let people = job.contacts.isEmpty
            ? "No contacts yet"
            : "\(job.contacts.count) contact\(job.contacts.count == 1 ? "" : "s")"
        guard let sector = job.sector, !sector.isEmpty else { return people }
        return "\(people) · \(sector)"
    }

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(company: job.company)

            // The chips sit on their own line rather than trailing the contact
            // count. Chips are intrinsically sized so they can't shrink, and on a
            // narrow phone a count plus two of them ran past the card's edge.
            VStack(alignment: .leading, spacing: 5) {
                Text(job.company)
                    .font(.headline)
                    .foregroundStyle(.ink)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)

                OutreachChips(job: job)
                    .padding(.top, 1)
            }
            // Fills the row, so the name only truncates when it really doesn't
            // fit — not to share the room with a Spacer.
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkFaint)
        }
        .padding(12)
        .panel()
    }
}

#Preview {
    HomeView()
        .environment(JobStore())
}
