import SwiftUI

/// Identifies one request to open the compose sheet, so `.sheet(item:)` mints a
/// fresh `SendMailView` identity per request — see `startCompose` for why.
private struct ComposeRequest: Identifiable {
    let id = UUID()
    let preselect: Set<Contact.ID>?
}

/// A company's detail screen: rich company metadata (name, sector, mail ID domain,
/// outreach metrics), a button to edit company details upstream, and a collapsible
/// button revealing the editable list of contacts.
struct JobDetailView: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(ReplySync.self) private var replySync
    let jobID: Job.ID

    @State private var isAdding = false
    @State private var editingCompany: Job?
    /// Open by default, and remembered: someone who collapses the list to read
    /// the header finds it collapsed on the next company too.
    @AppStorage("companyDetail.contactsExpanded") private var isContactsExpanded = true
    @State private var composeRequest: ComposeRequest?
    /// A compose asked for from the contact sheet, opened once that sheet is gone.
    @State private var pendingCompose: ComposeRequest?
    @State private var detailContact: Contact?
    @State private var selection = ListSelection<Contact.ID>()
    @State private var confirmingDelete = false
    @State private var pendingDelete: Contact?
    /// A Mark Invalid/Valid from a swipe, a menu or the selection bar, held until
    /// it's confirmed: it rewrites the shared contact row for every user.
    @State private var pendingValidity: ValidityChange?
    @State private var searchText = ""
    /// This company, while the Send chooser (by rule: not mailed yet, quiet,
    /// follow-ups…) is open for it.
    @State private var sendingTo: SendTarget?
    /// True until the first attempt to fetch a company that isn't in memory has
    /// finished, so the screen shows a spinner rather than "not found" meanwhile.
    @State private var isResolving = true

    /// Always read the live job from the store so edits show immediately. Looks in
    /// the full catalog first, so a company opened from the Companies tab renders
    /// even when it isn't tracked.
    private var job: Job? {
        jobStore.company(id: jobID)
    }

    /// Contacts show while expanded, and always while searching — a search typed
    /// into a collapsed list would otherwise look like it found nothing.
    private var showsContacts: Bool {
        isContactsExpanded || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// This company's contacts whose mail came back, newest first.
    private func bounced(_ job: Job) -> [BouncedContact] {
        guard !replySync.bounces.isEmpty else { return [] }
        let ids = Set(job.contacts.map(\.id))
        return jobStore.bouncedContacts(from: replySync).filter { ids.contains($0.contact.id) }
    }

    /// All the company's contacts, sorted by display name, in one list.
    private func sortedContacts(_ job: Job) -> [Contact] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return (query.isEmpty ? job.contacts : job.contacts.filter { $0.matches(query) }).sortedByName()
    }

    /// Sent mails are a permanent record, so only unsent ones can actually be
    /// removed. The bar counts what's selected; the delete dialog counts what will
    /// really go.
    private var deletableCount: Int {
        guard let job else { return 0 }
        return job.contacts.filter { selection.contains($0.id) && !$0.isSent }.count
    }

    /// The selected contacts that can actually be mailed.
    private var sendableCount: Int {
        guard let job else { return 0 }
        return job.contacts.filter {
            selection.contains($0.id) && $0.isMailable
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if let job {
                let contacts = sortedContacts(job)
                let bounces = bounced(job)
                let bouncedIDs = Set(bounces.map(\.contact.id))
                // Bounced contacts lead the list: they're the ones waiting on a
                // decision, and the card above points down to them.
                let active = contacts.filter { $0.isValid && bouncedIDs.contains($0.id) }
                    + contacts.filter { $0.isValid && !bouncedIDs.contains($0.id) }
                let invalid = contacts.filter { !$0.isValid }

                List(selection: $selection.ids) {
                    // Company details card (always visible at top)
                    // Margins on each row, not the section (see `cardRow`).
                    Section {
                        companyHeaderCard(job)
                            .cardRow(top: 8, bottom: 8)
                    }

                    if !bounces.isEmpty {
                        Section {
                            BounceSummaryCard(count: bounces.count,
                                              message: "\(bounces.count == 1 ? "It's" : "They're") first in the list below. Open one to see why, or fix the address.") {
                                pendingValidity = ValidityChange(bounces.map(\.contact), isValid: false)
                            }
                            .cardRow(top: 0, bottom: 8)
                        }
                    }

                    // Contacts list disclosure button & items
                    Section {
                        contactsToggleButton(job: job, active: active.count, invalid: invalid.count)
                            .cardRow()

                        if showsContacts {
                            if contacts.isEmpty {
                                emptyContactsNotice
                                    .cardRow()
                            } else {
                                contactRows(active, bounced: bouncedIDs)
                            }
                        }
                    }

                    // Ruled-out contacts keep their place in the company — they're
                    // the record of who has already been tried — but sit below
                    // everything live, in a sibling section (Lists don't nest them).
                    if showsContacts && !invalid.isEmpty {
                        Section {
                            contactRows(invalid, bounced: [])
                        } header: {
                            Label("Invalid · \(invalid.count)",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.statusInvalid)
                                .textCase(nil)
                        } footer: {
                            Text("Wrong address, or the person has left. These are never suggested and can't be mailed. Swipe right to put one back.")
                                .font(.footnote)
                                .foregroundStyle(.inkMuted)
                                .padding(.top, 4)
                        }
                    }
                }
                .cardList()
                .listRows(selection) { id in
                    detailContact = job.contacts.first { $0.id == id }
                } menu: { contactMenu($0) }
                .refreshable { await jobStore.load() }
                // Contacts moving between the live and invalid groups slide
                // there; not a bouncy spring, which the list applies to every
                // cell it moves and which reads as the cards colliding.
                .animation(Theme.Motion.snappy, value: active.map(\.id))
                .animation(Theme.Motion.snappy, value: invalid.map(\.id))
                // ...but not while typing into the contact search.
                .animation(nil, value: searchText)
            } else if jobStore.isLoading || isResolving {
                LoadingState()
            } else {
                ContentUnavailableView {
                    Label("Company Not Found", systemImage: "building.2")
                } description: {
                    Text("This company may have been deleted.")
                }
            }
        }
        .paperScreen()
        .navigationTitle(job?.company ?? "Company")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search contacts")
        .topBarActions(
            TopBarPrimary(title: "Add Contact", systemImage: "plus") {
                withAnimation(Theme.Motion.liquid) { isContactsExpanded = true }
                isAdding = true
            },
            isHidden: selection.isSelecting || job == nil
        ) {
            // Writing to the company — not to one person, or to a hand-picked
            // selection — had no way in from its own screen.
            Button {
                if let job { sendingTo = SendTarget(companies: [job]) }
            } label: {
                Label("Send…", systemImage: "paperplane")
            }
            .disabled(job?.validContacts.isEmpty ?? true)
            Button {
                editingCompany = job
            } label: {
                Label("Edit Company", systemImage: "pencil")
            }
            Button {
                withAnimation(Theme.Motion.liquid) { isContactsExpanded = true }
                selection.enter()
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            .disabled(job?.contacts.isEmpty ?? true)
            Divider()
            // A company opened from the catalog could only be put on Home by
            // going back and swiping its row.
            if jobStore.isTracked(jobID) {
                Button {
                    // The same reversible edit as Home's swipe, with its Undo.
                    Haptics.thud()
                    jobStore.untrack(companyID: jobID)
                    if let job {
                        let store = jobStore
                        UndoCoordinator.shared.stage(message: "Removed \(job.company) from Home") {
                            store.restoreJob(job)
                        }
                    }
                } label: {
                    Label("Remove from Home", systemImage: "pin.slash")
                }
            } else {
                Button {
                    Haptics.press()
                    jobStore.track(companyID: jobID)
                } label: {
                    Label("Track on Home", systemImage: "pin")
                }
            }
        }
        .selectionActions(
            selection,
            all: job.map { sortedContacts($0).map(\.id) } ?? [],
            noun: SelectionNoun(singular: "contact", plural: "contacts"),
            confirmingDelete: $confirmingDelete,
            deleteMessage: "This permanently deletes the selected contacts from the shared database, for every user. Sent ones are kept. This can't be undone.",
            deletableCount: deletableCount,
            sendableCount: sendableCount,
            onSend: {
                let chosen = selection.ids
                selection.exit()
                startCompose(preselect: chosen)
            },
            bulkAction: validityAction,
            onDelete: deleteSelected
        )
        .uniformDeleteAlert(
            item: $pendingDelete,
            title: { "Delete “\($0.displayName)”?" },
            message: "This permanently deletes the contact from the shared database, for every user. This can't be undone."
        ) { contact in
            Task { await jobStore.deleteContact(contact) }
        }
        .validityAlert($pendingValidity) { change in
            // From the selection bar or a selection's menu: the act is done, so
            // the mode is too. Cancelling leaves the selection as it was.
            if selection.isSelecting { selection.exit() }
            Task {
                if change.isValid {
                    await jobStore.setValidity(change.ids, isValid: true)
                } else {
                    // Clears any bounce they had, too.
                    await jobStore.markBouncedInvalid(change.ids, sync: replySync)
                }
            }
        }
        .companyEditor(for: $editingCompany)
        .sendChooser(for: $sendingTo) {}
        .addContactSheet(isPresented: $isAdding, initialCompany: job)
        .sheet(item: $detailContact, onDismiss: {
            // Mail from the contact card: its sheet had to go first.
            if let pendingCompose {
                composeRequest = pendingCompose
                self.pendingCompose = nil
            }
        }) { contact in
            ContactDetailView(
                contact: contact,
                company: job?.company ?? "",
                onCompose: {
                    pendingCompose = ComposeRequest(preselect: [contact.id])
                    detailContact = nil
                },
                onSetValidity: { isValid in
                    Task {
                        if isValid {
                            await jobStore.setValidity([contact.id], isValid: true)
                        } else {
                            await jobStore.markBouncedInvalid([contact.id], sync: replySync)
                        }
                    }
                }
            ) { updated in
                Task { await jobStore.updateContact(updated) }
            }
        }
        .sheet(item: $composeRequest) { request in
            if let job { SendMailView(job: job, preselect: request.preselect) }
        }
        .undoBanner()
        .task(id: jobID) {
            await jobStore.loadCompanyIfNeeded(id: jobID)
            isResolving = false
        }
    }

    // MARK: - Company Details Card

    private func companyHeaderCard(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                MonogramAvatar(company: job.company)

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.company)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if let sector = job.sector, !sector.isEmpty {
                        // Two lines, not one: sectors run long ("Internet and
                        // consumer products"), and a sector cut to "Internet
                        // and c…" says less than no sector at all.
                        Text(sector)
                            .font(.subheadline)
                            .foregroundStyle(Color.inkMuted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // An icon, not a labelled pill: the word "Edit" at large text
                // sizes took the width the company's own name needed.
                Button {
                    Haptics.press()
                    editingCompany = job
                } label: {
                    Image(systemName: "pencil")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.clay)
                        .frame(width: 22, height: 22)
                }
                .secondaryButton()
                .buttonBorderShape(.circle)
                .accessibilityLabel("Edit company")
            }

            domainChips(job)

            Divider().overlay(Color.hairline)

            // Figures over captions in three equal columns — side by side, a
            // figure and its word competed for one line and "Contacts" broke
            // into "Con-tacts".
            HStack(spacing: 0) {
                Metric(value: job.contacts.count, caption: "Contacts", size: 22)
                MetricDivider()
                Metric(value: job.contacts.filter(\.isSent).count, caption: "Sent", size: 22)
                MetricDivider()
                Metric(value: job.repliedContacts.count, caption: "Replied",
                       tint: job.repliedContacts.isEmpty ? .ink : .olive, size: 22)
            }
        }
        .padding(16)
        .panel()
    }

    /// Every domain the company answers to, wrapping onto as many lines as it
    /// needs. Listed ones are solid; ones only seen on contacts' addresses are
    /// dashed, and tapping one opens the editor where it's a one-tap add.
    @ViewBuilder
    private func domainChips(_ job: Job) -> some View {
        let domains = job.allDomains
        if domains.isEmpty {
            Button {
                editingCompany = job
            } label: {
                Label("Add a mail domain", systemImage: "at")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.inkFaint)
            }
            .buttonStyle(.plain)
        } else {
            WrappingHStack(spacing: 6, lineSpacing: 6) {
                ForEach(domains, id: \.self) { domain in
                    let listed = job.domains.contains(domain)
                    DomainChip(domain: domain, listed: listed)
                        .onTapGesture { if !listed { editingCompany = job } }
                        .accessibilityAddTraits(listed ? [] : .isButton)
                }
            }
        }
    }

    // MARK: - Contacts Section & Toggle Button

    private func contactsToggleButton(job: Job, active: Int, invalid: Int) -> some View {
        Button {
            Haptics.tap()
            withAnimation(Theme.Motion.liquid) { isContactsExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.body)
                    .foregroundStyle(Color.clay)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Contacts")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    // The full breakdown when it fits on one line, the active
                    // count alone when the avatar peek needs the room.
                    ViewThatFits(in: .horizontal) {
                        Text(invalid == 0 ? "\(active) active" : "\(active) active · \(invalid) invalid")
                        Text("\(active) active")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                // Collapsed, the row previews who's inside rather than only how
                // many — the faces are what you'd open it to look for.
                if !showsContacts && !job.contacts.isEmpty {
                    avatarPeek(job.validContacts.isEmpty ? job.contacts : job.validContacts)
                        .transition(LiquidMaterialize(scale: 0.7, anchor: .trailing))
                }

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.inkFaint)
                    .rotationEffect(.degrees(showsContacts ? 180 : 0))
            }
            .padding(14)
            .contentShape(.rect)
            .panel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Contacts, \(job.contacts.count)")
        .accessibilityValue(showsContacts ? "Expanded" : "Collapsed")
        .accessibilityHint(showsContacts ? "Collapses the list" : "Shows the list")
    }

    /// Up to three overlapping avatars, then a "+N".
    private func avatarPeek(_ contacts: [Contact]) -> some View {
        let shown = contacts.prefix(3)
        return HStack(spacing: -8) {
            ForEach(shown) { contact in
                MonogramAvatar(text: contact.displayName, size: 26)
                    .overlay(Circle().strokeBorder(Color.paperRaised, lineWidth: 2))
            }
            if contacts.count > shown.count {
                Text("+\(contacts.count - shown.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.inkMuted)
                    .padding(.leading, 12)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var emptyContactsNotice: some View {
        VStack(spacing: 12) {
            Text("No contacts listed for this company yet.")
                .font(.subheadline)
                .foregroundStyle(Color.inkMuted)

            Button {
                isAdding = true
            } label: {
                Label("Add Contact", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .primaryButton()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .panel()
    }

    /// Open the compose sheet. Pass `preselect` to send to specific contacts.
    private func startCompose(preselect: Set<Contact.ID>? = nil) {
        composeRequest = ComposeRequest(preselect: preselect)
    }

    private var validityAction: SelectionBulkAction? {
        guard let job else { return nil }
        let picked = job.contacts.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        let allInvalid = picked.allSatisfy { !$0.isValid }
        return SelectionBulkAction(
            title: allInvalid ? "Mark Valid" : "Mark Invalid",
            systemImage: allInvalid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tint: allInvalid ? Color.statusDone : Color.statusInvalid
        ) {
            pendingValidity = ValidityChange(picked, isValid: allInvalid)
        }
    }

    private func deleteSelected() {
        guard let job else { return }
        let toDelete = job.contacts.filter { selection.contains($0.id) }
        selection.exit()
        Task { await jobStore.deleteContacts(toDelete) }
    }

    /// A held contact's menu — or, while selecting, the menu for everyone ticked.
    @ViewBuilder
    private func contactMenu(_ ids: Set<Contact.ID>) -> some View {
        let contacts = job?.contacts.filter { ids.contains($0.id) } ?? []
        if !contacts.isEmpty {
            let sendable = contacts.filter(\.isMailable)
            let allInvalid = contacts.allSatisfy { !$0.isValid }
            Button {
                startCompose(preselect: Set(sendable.map(\.id)))
            } label: {
                Label("Send…", systemImage: "paperplane")
            }
            .disabled(sendable.isEmpty)
            if contacts.count == 1, let contact = contacts.first {
                let isBounced = replySync.bounces[contact.id] != nil && contact.isValid
                Button { detailContact = contact } label: {
                    Label(isBounced ? "Why It Bounced" : "Details",
                          systemImage: isBounced ? "arrow.uturn.backward.circle" : "person.text.rectangle")
                }
                if isBounced {
                    Button {
                        Haptics.tap(0.5)
                        withAnimation(Theme.Motion.snappy) { replySync.dismissBounce(contact.id) }
                    } label: {
                        Label("Not a Bounce", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            Button {
                pendingValidity = ValidityChange(contacts, isValid: allInvalid)
            } label: {
                Label(allInvalid ? "Mark Valid" : "Mark Invalid",
                      systemImage: allInvalid ? "checkmark.circle" : "exclamationmark.triangle")
            }
            if !selection.isSelecting {
                Button { selection.begin(with: ids) } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
            // Sent mails are a permanent record, so a contact who's been mailed
            // can't be deleted — the same rule as the swipe.
            if contacts.contains(where: { !$0.isSent }) {
                Divider()
                Button(role: .destructive) {
                    Haptics.warning()
                    if contacts.count == 1 {
                        pendingDelete = contacts.first
                    } else {
                        // Only a selection offers more than one row to a menu,
                        // so this is the bar's own delete, with its own dialog.
                        confirmingDelete = true
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func contactRows(_ contacts: [Contact], bounced: Set<Contact.ID>) -> some View {
        ForEach(contacts) { contact in
            ContactRow(
                contact: contact,
                isBounced: bounced.contains(contact.id),
                onSend: contact.isValid ? { startCompose(preselect: [contact.id]) } : nil
            )
            .cardRow()
            .tag(contact.id)
            .swipeActions(edge: .trailing) {
                if !contact.isSent {
                    Button(role: .destructive) {
                        Haptics.warning()
                        pendingDelete = contact
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .swipeActions(edge: .leading) {
                // A full swipe fires this straight away, so it asks first
                // rather than rewriting the shared row mid-gesture.
                Button {
                    pendingValidity = ValidityChange([contact], isValid: !contact.isValid)
                } label: {
                    Label(contact.isValid ? "Invalid" : "Valid",
                          systemImage: contact.isValid
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                }
                .tint(contact.isValid ? Color.statusInvalid : Color.statusDone)
            }
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    /// Their last mail came back undelivered.
    var isBounced = false
    var onSend: (() -> Void)? = nil

    /// Always a second line, so every contact card is the same height: the job
    /// title, else the address — unless the address is already the headline.
    private var subtitle: String {
        if !contact.position.isEmpty { return contact.position }
        return contact.name.isEmpty ? "No name or title on file" : contact.email
    }

    private var subtitleIsPlaceholder: Bool {
        contact.position.isEmpty && contact.name.isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(text: contact.displayName, size: Theme.Avatar.small)
                .grayscale(contact.isValid ? 0 : 1)
                .opacity(contact.isValid ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.headline)
                    .foregroundStyle(contact.isValid ? Color.ink : Color.inkMuted)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(contact.isValid && !subtitleIsPlaceholder
                                     ? Color.inkMuted : Color.inkFaint)
                    .lineLimit(1)
            }
            // Fills the row rather than sharing it with a Spacer, so the address
            // gets every point the chip and button leave.
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if !contact.isValid {
                    InvalidPill()
                } else if isBounced {
                    BouncedPill()
                } else if contact.hasReplied {
                    RepliedPill(at: contact.repliedAt)
                } else {
                    SentPill(sentAt: contact.sentAt)
                }
                if let onSend {
                    Button {
                        Haptics.press()
                        onSend()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .background(.tint.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(BouncyPress(scale: 0.82))
                    .accessibilityLabel(contact.isSent ? "Send again to \(contact.displayName)" : "Send to \(contact.displayName)")
                }
            }
            // The send button's height, held even for an invalid contact that has
            // no button, so ruling someone out doesn't shrink their card.
            .frame(minHeight: 36)
        }
        .padding(12)
        .panelAccented(cardAccent)
        .animation(Theme.Motion.pop, value: contact.isValid)
        .animation(Theme.Motion.pop, value: contact.hasReplied)
    }

    private var cardAccent: Color? {
        if !contact.isValid { return .inkFaint }
        if isBounced { return .statusInvalid }
        return contact.hasReplied ? .statusDone : nil
    }
}
