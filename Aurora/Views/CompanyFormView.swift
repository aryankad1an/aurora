import SwiftUI

/// A form to create a new company or edit an existing one's name, sector, and
/// mail domains. All fields write upstream to the shared catalog (for every user).
///
/// A company can have any number of domains. Most never need typing: adding a
/// contact teaches the company its domain (see `JobStore.addContact`), and the
/// ones its contacts already use are offered here as one-tap suggestions.
struct CompanyFormView: View {
    /// The company being edited; nil when creating one.
    var companyID: String?
    let title: String
    let confirmLabel: String
    /// Work domains seen on the company's contacts that aren't listed yet.
    let suggestedDomains: [String]
    let onSave: (_ name: String, _ sector: String, _ domains: [String]) -> Void

    private let initialName: String
    private let initialSector: String
    private let initialDomains: [String]

    @State private var name: String
    @State private var sector: String
    @State private var domains: [String]
    @State private var newDomain = ""
    @FocusState private var isDomainFieldFocused: Bool
    @FocusState private var focus: Field?
    private enum Field { case name, sector }
    /// Other companies already using each domain, looked up as domains are added.
    @State private var owners: [String: [String]] = [:]
    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss

    init(companyID: String? = nil,
         name: String = "", sector: String = "", domains: [String] = [],
         suggestedDomains: [String] = [],
         title: String, confirmLabel: String,
         onSave: @escaping (_ name: String, _ sector: String, _ domains: [String]) -> Void) {
        self.companyID = companyID
        self.initialName = name
        self.initialSector = sector
        self.initialDomains = domains
        self.suggestedDomains = suggestedDomains
        _name = State(initialValue: name)
        _sector = State(initialValue: sector)
        _domains = State(initialValue: domains)
        self.title = title
        self.confirmLabel = confirmLabel
        self.onSave = onSave
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedSector: String { sector.trimmingCharacters(in: .whitespaces) }

    /// The domain being typed, once it is one.
    private var pendingDomain: String? {
        MailDomain.clean(newDomain).flatMap { domains.contains($0) ? nil : $0 }
    }

    /// Everything that will be saved, including a domain typed but not yet added
    /// — tapping Save with one in the field shouldn't quietly lose it.
    private var finalDomains: [String] {
        domains + (pendingDomain.map { [$0] } ?? [])
    }

    private var remainingSuggestions: [String] {
        suggestedDomains.filter { !domains.contains($0) }
    }

    private var hasChanges: Bool {
        trimmedName != initialName.trimmingCharacters(in: .whitespaces)
            || trimmedSector != initialSector.trimmingCharacters(in: .whitespaces)
            || finalDomains != initialDomains
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section("Company") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .textContentType(.organizationName)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .sector }
                        // A new company starts with the cursor in its name, once
                        // the sheet has risen, as a new contact does in
                        // Contacts; an edit leaves the keyboard down.
                        .task {
                            guard companyID == nil, focus == nil else { return }
                            try? await Task.sleep(for: .milliseconds(400))
                            focus = .name
                        }
                    TextField("Sector (optional)", text: $sector)
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .sector)
                        .submitLabel(.next)
                        .onSubmit { isDomainFieldFocused = true }
                }
                domainsSection
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .animation(Theme.Motion.snappy, value: domains)
            .animation(Theme.Motion.snappy, value: owners)
            .task(id: finalDomains) { await lookUpOwners() }
            .discardableEdits(hasChanges)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        Haptics.success()
                        onSave(trimmedName, trimmedSector, finalDomains)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || !hasChanges)
                }
            }
        }
    }

    private var domainsSection: some View {
        Section {
            ForEach(domains, id: \.self) { domain in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(domain)")
                            .font(.body.monospaced())
                            .foregroundStyle(Color.ink)
                        ownerNote(for: domain)
                    }
                    Spacer()
                    Button {
                        Haptics.tap()
                        domains.removeAll { $0 == domain }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Color.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(domain)")
                }
            }

            HStack {
                TextField("Add a domain, e.g. stripe.com", text: $newDomain)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .focused($isDomainFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(addPendingDomain)
                Button(action: addPendingDomain) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(pendingDomain == nil ? Color.inkFaint : Color.clay)
                }
                .buttonStyle(.plain)
                .disabled(pendingDomain == nil)
                .accessibilityLabel("Add domain")
            }
            if let pendingDomain { ownerNote(for: pendingDomain) }

            if !remainingSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("From contacts")
                            .font(.caption)
                            .foregroundStyle(Color.inkMuted)
                        ForEach(remainingSuggestions, id: \.self) { domain in
                            // Dashed, as on the company screen: seen on contacts,
                            // not yet saved. Tapping saves it.
                            Button {
                                Haptics.select()
                                domains.append(domain)
                            } label: {
                                DomainChip(domain: domain, listed: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Adds it to this company")
                        }
                    }
                }
            }
        } header: {
            Text("Mail domains")
        } footer: {
            Text(SupabaseAPI.domainsColumnMissing
                 ? "Domains can't be saved until the database has been updated — run the “companies.domains” migration from the README."
                 : "New contacts with these addresses are suggested for this company. A company can have several.")
        }
    }

    /// Says so when a domain already belongs to another company — the moment to
    /// notice a duplicate is before it's created, not after.
    @ViewBuilder
    private func ownerNote(for domain: String) -> some View {
        if let names = owners[domain], !names.isEmpty {
            Label("Also used by \(ListFormatter.localizedString(byJoining: names))",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.kraft)
        }
    }

    private func lookUpOwners() async {
        guard await Task.debounce(.milliseconds(300)) else { return }
        for domain in finalDomains where owners[domain] == nil {
            guard !Task.isCancelled else { return }
            guard let found = try? await jobStore.companies(forDomain: domain) else { continue }
            owners[domain] = found.filter { $0.id != companyID }.map(\.company)
        }
    }

    private func addPendingDomain() {
        guard let domain = pendingDomain else { return }
        Haptics.select()
        domains.append(domain)
        newDomain = ""
        isDomainFieldFocused = true
    }
}

extension View {
    /// The Edit Company sheet for `company`, wired to the store: shown while
    /// it's set, saved upstream with an undo window.
    func companyEditor(for company: Binding<Job?>) -> some View {
        modifier(CompanyEditorSheet(company: company))
    }
}

private struct CompanyEditorSheet: ViewModifier {
    @Binding var company: Job?
    @Environment(JobStore.self) private var jobStore

    func body(content: Content) -> some View {
        content.sheet(item: $company) { company in
            CompanyFormView(
                companyID: company.id,
                name: company.company,
                sector: company.sector ?? "",
                domains: company.domains,
                suggestedDomains: company.contactDomains,
                title: "Edit Company",
                confirmLabel: "Save"
            ) { name, sector, domains in
                Task {
                    await jobStore.updateCompany(id: company.id, name: name,
                                                 sector: sector.isEmpty ? nil : sector,
                                                 domains: domains)
                }
            }
        }
    }
}
