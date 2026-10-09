import SwiftUI

/// Add a new contact. Editing an existing one happens in `ContactDetailView`.
///
/// The company is suggested from the address. As soon as the email has a work
/// domain, the catalog is asked who already uses it — on a company's row or on
/// any of its contacts — and the form offers that company. It's what keeps the
/// catalog free of duplicates without anyone ever having to merge two: the
/// second "Stripe Inc" never gets created, because typing `@stripe.com` already
/// pointed at Stripe.
struct ContactFormView: View {
    /// The company the form opened from, if any. Preselected, but a domain match
    /// elsewhere is still offered — adding someone to the wrong company is
    /// exactly the mistake this form is built to catch.
    var initialCompany: Job?
    let onSave: (Contact, JobStore.ContactDestination) -> Void

    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var name = ""
    @State private var phone = ""
    @State private var position = ""
    @State private var greetingName = ""

    @State private var destination: JobStore.ContactDestination?
    /// Set once the user picks a company themselves, so a suggestion never
    /// overrides a deliberate choice.
    @State private var userChoseCompany = false
    @State private var isPickingCompany = false

    /// Companies already on file for `domain`, and the domain they were looked
    /// up for (the lookup trails the typing).
    @State private var matches: [Job] = []
    @State private var matchedDomain: String?
    @State private var isLookingUp = false

    init(initialCompany: Job? = nil, onSave: @escaping (Contact, JobStore.ContactDestination) -> Void) {
        self.initialCompany = initialCompany
        self.onSave = onSave
        _destination = State(initialValue: initialCompany.map { .existing($0) })
    }

    /// The work domain of the address being typed; nil for a personal mailbox.
    private var domain: String? { MailDomain.work(fromEmail: email) }

    private var selectedCompany: Job? {
        if case .existing(let job) = destination { return job }
        return nil
    }

    /// Current matches, once the lookup has caught up with the address.
    private var currentMatches: [Job] {
        matchedDomain == domain ? matches : []
    }

    private var canSave: Bool {
        ContactFields.isValid(email: email, name: name) && destination != nil
    }

    /// Anything typed, or a company chosen other than the one it opened with.
    private var hasChanges: Bool {
        ![email, name, phone, position, greetingName].allSatisfy { $0.isEmpty }
            || selectedCompany?.id != initialCompany?.id
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                ContactFields(email: $email, name: $name, position: $position, phone: $phone,
                              greetingName: $greetingName, focusesFirstField: true)
                companySection
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $isPickingCompany) {
                CompanyPickerView { picked in
                    userChoseCompany = true
                    withAnimation(Theme.Motion.snappy) { destination = picked }
                }
            }
            .discardableEdits(hasChanges)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .task(id: domain) { await lookUpDomain() }
            .animation(Theme.Motion.snappy, value: currentMatches.map(\.id))
            .animation(Theme.Motion.snappy, value: isLookingUp)
        }
    }

    // MARK: - Company

    private var companySection: some View {
        Section {
            Button {
                isPickingCompany = true
            } label: {
                HStack(spacing: 12) {
                    MonogramAvatar(company: destinationName ?? "?", size: Theme.Avatar.small)
                        .opacity(destination == nil ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destinationName ?? "Choose a company")
                            .font(.headline)
                            .foregroundStyle(destination == nil ? Color.inkMuted : Color.ink)
                        if case .new = destination {
                            Text("New company")
                                .font(.caption)
                                .foregroundStyle(Color.clay)
                        } else if let selectedCompany, !selectedCompany.allDomains.isEmpty {
                            Text(selectedCompany.allDomains.prefix(2).map { "@\($0)" }.joined(separator: "  "))
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(destinationName.map { "Company, \($0)" } ?? "Choose a company")

            if let domain {
                if isLookingUp && matchedDomain != domain {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up @\(domain)…")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkMuted)
                    }
                } else {
                    ForEach(currentMatches.filter { $0.id != selectedCompany?.id }) { match in
                        suggestionRow(match, domain: domain)
                    }
                }
            }
        } header: {
            Text("Company")
        } footer: {
            if let footer = companyFooter { Text(footer) }
        }
    }

    private var destinationName: String? {
        switch destination {
        case .existing(let job): job.company
        case .new(let name): name
        case nil: nil
        }
    }

    /// "The database found this domain at…" — one tap moves the contact there.
    private func suggestionRow(_ match: Job, domain: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.body)
                .foregroundStyle(Color.clay)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(domain) is on file at \(match.company)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text("\(match.contacts.count) contact\(match.contacts.count == 1 ? "" : "s")"
                     + (match.domains.contains(domain) ? " · listed domain" : " · from its contacts"))
                    .font(.caption)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 8)
            Button("Use") {
                Haptics.press()
                userChoseCompany = true
                withAnimation(Theme.Motion.snappy) { destination = .existing(match) }
            }
            .font(.subheadline.weight(.semibold))
            .primaryButton()
        }
        .transition(LiquidMaterialize(scale: 0.94, anchor: .top))
    }

    private var companyFooter: String? {
        let emailKey = email.lowercased()
        if let selectedCompany, selectedCompany.contacts.contains(where: { $0.email.lowercased() == emailKey }) {
            return "\(email) is already a contact at \(selectedCompany.company). Saving updates their details."
        }
        guard let domain, matchedDomain == domain, !isLookingUp else {
            if !email.isEmpty, email.contains("@"), domain == nil {
                return "Personal addresses don't identify a company, so pick one yourself."
            }
            return nil
        }
        switch destination {
        case .existing(let job) where currentMatches.contains(where: { $0.id == job.id }):
            return "@\(domain) belongs to \(job.company)."
        case .existing(let job) where currentMatches.isEmpty:
            return "@\(domain) is new to the database. It'll be added to \(job.company)'s domains."
        case .existing(let job):
            return "@\(domain) is used elsewhere, so it won't be added to \(job.company)'s domains."
        case .new(let name):
            return currentMatches.isEmpty ? "\(name) will be created with @\(domain)." : nil
        case nil:
            return currentMatches.isEmpty ? "No company uses @\(domain) yet. Choose one, or create it." : nil
        }
    }

    /// Ask the catalog who uses the typed domain. Driven by `.task(id: domain)`,
    /// so typing cancels the previous lookup and the pause debounces it.
    private func lookUpDomain() async {
        guard let domain else {
            matches = []; matchedDomain = nil; isLookingUp = false
            return
        }
        isLookingUp = true
        guard await Task.debounce(.milliseconds(350)) else { return }
        let found = (try? await jobStore.companies(forDomain: domain)) ?? []
        guard !Task.isCancelled else { return }
        matches = found
        matchedDomain = domain
        isLookingUp = false

        // Nothing chosen yet and exactly one company fits: that's the answer.
        if !userChoseCompany, destination == nil, found.count == 1 {
            Haptics.select()
            withAnimation(Theme.Motion.snappy) { destination = .existing(found[0]) }
        }
    }

    private func save() {
        guard let destination else { return }
        Haptics.success()
        onSave(Contact(
            email: email.lowercased().trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            phone: phone.isEmpty ? nil : phone,
            position: position,
            greetingName: greetingName.isEmpty ? nil : greetingName
        ), destination)
        dismiss()
    }
}

/// Pick the company a new contact belongs to — any in the catalog, or a new one
/// named after the search.
struct CompanyPickerView: View {
    let onPick: (JobStore.ContactDestination) -> Void

    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var remote: [Job] = []

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var results: [Job] {
        query.isEmpty ? jobStore.allCompanies : .matching(query, in: jobStore.allCompanies, remote)
    }

    private var canCreate: Bool {
        !query.isEmpty && !results.contains { $0.company.caseInsensitiveCompare(query) == .orderedSame }
    }

    var body: some View {
        PaperList {
            if canCreate {
                Button {
                    pick(.new(name: query))
                } label: {
                    Label("Create “\(query)”", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color.clay)
                }
            }
            ForEach(results) { company in
                Button {
                    pick(.existing(company))
                } label: {
                    HStack(spacing: 12) {
                        MonogramAvatar(company: company.company, size: Theme.Avatar.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(company.company)
                                .font(.headline)
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            // Always a second line, so the results are one height.
                            Text(company.mailDomain.isEmpty ? "No mail domain" : "@\(company.mailDomain)")
                                .font(.caption.monospaced())
                                .foregroundStyle(company.mailDomain.isEmpty ? Color.inkFaint : Color.inkMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(company.contacts.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.inkMuted)
                    }
                }
            }
        }
        .navigationTitle("Company")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search, or type a new name")
        .task(id: query) {
            guard !query.isEmpty else { remote = []; return }
            guard await Task.debounce(.milliseconds(250)) else { return }
            if let found = try? await SupabaseAPI.searchCompanies(query: query), !Task.isCancelled {
                remote = found
            }
        }
    }

    private func pick(_ destination: JobStore.ContactDestination) {
        Haptics.select()
        onPick(destination)
        dismiss()
    }
}

/// The shared contact form fields, reused by add and edit.
///
/// Read-only mode isn't just "the same fields, disabled". A disabled `TextField`
/// renders its value with no label at all, so a filled-in detail screen became a
/// stack of anonymous strings — you could read "HARMESH ROHIT" but nothing said
/// which field it was. `LabeledContent` names each value instead.
struct ContactFields: View {
    @Binding var email: String
    @Binding var name: String
    @Binding var position: String
    @Binding var phone: String
    @Binding var greetingName: String
    var isEditing = true
    var header = "Contact"
    /// The `From:` of their reply, if they've replied: the greeting can come
    /// from the name they signed it with, so the preview has to see it too.
    var replyFrom: String? = nil
    /// Put the cursor in the first field as the form opens — for adding someone,
    /// where typing is the only thing to do next.
    var focusesFirstField = false

    @FocusState private var focus: Field?
    private enum Field { case email, name, greeting, position, phone }

    static func isValid(email: String, name: String) -> Bool {
        MailDomain.isPlausibleAddress(email) && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What a mail to this contact would open with, as edited right now — the
    /// override if one is typed, otherwise what gets derived from the name and
    /// address. Shown under the fields so the effect of filling in "Greeting
    /// Name" is visible before anything is sent.
    private var greetingPreview: String {
        Contact(email: email, name: name, greetingName: greetingName, replyFrom: replyFrom).greeting
    }

    var body: some View {
        Section {
            if isEditing {
                // Return moves down the form, the way Contacts' does.
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .name }
                    // On the field, not the Section: a modifier on a Section
                    // stops the Form treating it as one, and its header and
                    // footer fall inside the card.
                    .task {
                        guard focusesFirstField, focus == nil else { return }
                        // Once the sheet has finished rising, as Contacts does.
                        try? await Task.sleep(for: .milliseconds(400))
                        focus = .email
                    }
                    .onChange(of: email) { _, value in
                        if value != value.lowercased() { email = value.lowercased() }
                    }
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .greeting }
                TextField("Greeting Name (optional)", text: $greetingName)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .greeting)
                    .submitLabel(.next)
                    .onSubmit { focus = .position }
                TextField("Position (optional)", text: $position)
                    .textContentType(.jobTitle)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .position)
                    .submitLabel(.next)
                    .onSubmit { focus = .phone }
                TextField("Phone Number (optional)", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focus, equals: .phone)
            } else {
                // Selectable, so a hold copies the address the way it does in
                // Contacts — this screen is often where it's looked up.
                if !name.isEmpty { LabeledContent("Name", value: name) }
                LabeledContent("Email", value: email)
                    .textSelection(.enabled)
                if !position.isEmpty { LabeledContent("Position", value: position) }
                if !phone.isEmpty {
                    LabeledContent("Phone", value: phone)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text(header)
        } footer: {
            Text(greetingPreview.isEmpty
                 ? "Mail opens “Hi,” — no name here it can trust. Add a Greeting Name to use one."
                 : "Mail opens “Hi \(greetingPreview),”")
        }
    }
}

extension View {
    /// The Add Contact sheet, wired to the store: every screen that offers
    /// "Add Contact" presents exactly this.
    func addContactSheet(isPresented: Binding<Bool>, initialCompany: Job? = nil) -> some View {
        modifier(AddContactSheet(isPresented: isPresented, initialCompany: initialCompany))
    }
}

private struct AddContactSheet: ViewModifier {
    @Binding var isPresented: Bool
    let initialCompany: Job?
    @Environment(JobStore.self) private var jobStore

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ContactFormView(initialCompany: initialCompany) { contact, destination in
                Task { await jobStore.addContact(contact, to: destination) }
            }
        }
    }
}
