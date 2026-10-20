import SwiftUI

/// A form to create a new company or edit an existing one: its name and sector,
/// its logo and links, how it hires freshers, and its mail domains. All fields
/// write upstream to the shared catalog (for every user), except its LinkedIn,
/// X and Facebook pages, which are sealed into this account's own vault.
///
/// A company can have any number of domains. Most never need typing: adding a
/// contact teaches the company its domain (see `JobStore.addContact`), and the
/// ones its contacts already use are offered here as one-tap suggestions.
///
/// Sources aren't part of the draft: they're rows of their own, and save as
/// they're changed, from the Sources screen this form links to.
struct CompanyFormView: View {
    /// The company being edited; nil when creating one.
    var companyID: String?
    let title: String
    let confirmLabel: String
    /// Work domains seen on the company's contacts that aren't listed yet.
    let suggestedDomains: [String]
    let onSave: (CompanyDetails) -> Void

    @State private var initial: CompanyDetails
    /// Whether the company's links are on hand to edit. Until they are, their
    /// fields stay off, so a save can't wipe links it never saw.
    @State private var linksReady: Bool
    /// Set when they couldn't be fetched, so the form stops showing them as loading.
    @State private var linksUnavailable = false
    /// Where the links on file came from, to say so under them.
    private let websiteSource: String?
    private let careersSource: String?

    @State private var draft: CompanyDetails
    @State private var newDomain = ""
    @State private var newBatch = ""
    @State private var newRole = ""
    @State private var newOtherName = ""
    @State private var isFindingLogo = false
    @State private var logoNote: String?
    @FocusState private var isDomainFieldFocused: Bool
    @FocusState private var focus: Field?
    private enum Field { case name, sector, otherName, website, careers, logo, batch, role, linkedIn, x, facebook }
    /// Other companies already using each domain, looked up as domains are added.
    @State private var owners: [String: [String]] = [:]
    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss

    init(companyID: String? = nil,
         details: CompanyDetails = CompanyDetails(),
         websiteSource: String? = nil, careersSource: String? = nil,
         suggestedDomains: [String] = [],
         title: String, confirmLabel: String,
         onSave: @escaping (CompanyDetails) -> Void) {
        self.companyID = companyID
        _initial = State(initialValue: details)
        _linksReady = State(initialValue: companyID == nil)
        self.websiteSource = websiteSource
        self.careersSource = careersSource
        self.suggestedDomains = suggestedDomains
        _draft = State(initialValue: details)
        self.title = title
        self.confirmLabel = confirmLabel
        self.onSave = onSave
    }

    /// The domain being typed, once it is one.
    private var pendingDomain: String? {
        MailDomain.clean(newDomain).flatMap { draft.domains.contains($0) ? nil : $0 }
    }

    /// A graduation year being typed, once it is one.
    private var pendingBatch: String? {
        let year = newBatch.trimmingCharacters(in: .whitespaces)
        guard let n = Int(year), (2000...2100).contains(n), !draft.batches.contains(year) else { return nil }
        return year
    }

    private var pendingRole: String? {
        let role = newRole.trimmingCharacters(in: .whitespaces)
        guard !role.isEmpty, !draft.fresherRoles.contains(where: { $0.caseInsensitiveCompare(role) == .orderedSame })
        else { return nil }
        return role
    }

    private var pendingOtherName: String? {
        let name = newOtherName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.caseInsensitiveCompare(draft.name.trimmingCharacters(in: .whitespaces)) != .orderedSame,
              !draft.alsoKnownAs.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return name
    }

    /// Everything that will be saved, including a domain, year or role typed
    /// but not yet added — tapping Save with one in its field shouldn't
    /// quietly lose it.
    private var finalDetails: CompanyDetails {
        var d = draft
        if let pendingDomain { d.domains.append(pendingDomain) }
        if let pendingBatch { d.batches.append(pendingBatch) }
        if let pendingRole { d.fresherRoles.append(pendingRole) }
        if let pendingOtherName { d.alsoKnownAs.append(pendingOtherName) }
        if !d.isFresher { d.isOpenNow = false }
        return d.trimmed
    }

    private var hasChanges: Bool { finalDetails != initial.trimmed }

    private var remainingSuggestions: [String] {
        suggestedDomains.filter { !draft.domains.contains($0) }
    }

    /// The links and fresher details need the fresher-hiring migration.
    private var canStoreFresherDetails: Bool { !SupabaseAPI.fresherColumnsMissing }

    /// LinkedIn, X and Facebook need the company-links table and this
    /// account's own vault, unlocked, to seal them into.
    private var canStoreSocialLinks: Bool {
        !SupabaseAPI.companyLinksTableMissing && KeyRing.shared.ownVaultID != nil
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                companySection
                if !SupabaseAPI.alsoKnownAsColumnMissing {
                    otherNamesSection
                }
                if canStoreFresherDetails {
                    linksSection
                }
                if canStoreSocialLinks {
                    socialLinksSection
                }
                if canStoreFresherDetails {
                    fresherSection
                }
                domainsSection
                if let companyID, canStoreFresherDetails, !SupabaseAPI.sourcesTableMissing {
                    sourcesSection(companyID)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The lists that grow and shrink, not every keystroke.
            .animation(Theme.Motion.snappy, value: draft.domains)
            .animation(Theme.Motion.snappy, value: draft.batches)
            .animation(Theme.Motion.snappy, value: draft.fresherRoles)
            .animation(Theme.Motion.snappy, value: draft.alsoKnownAs)
            .animation(Theme.Motion.snappy, value: owners)
            .task(id: finalDetails.domains) { await lookUpOwners() }
            .discardableEdits(hasChanges)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        Haptics.success()
                        onSave(finalDetails)
                        dismiss()
                    }
                    .disabled(finalDetails.name.isEmpty || !hasChanges || !finalDetails.invalidLinkFields.isEmpty)
                }
            }
        }
    }

    // MARK: - Company

    private var companySection: some View {
        Section {
            TextField("Name", text: $draft.name)
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
            TextField("Sector (optional)", text: $draft.sector)
                .textInputAutocapitalization(.words)
                .focused($focus, equals: .sector)
                .submitLabel(.next)
                .onSubmit { focus = canStoreFresherDetails ? .website : nil }
        } header: {
            Text("Company")
        } footer: {
            if !canStoreFresherDetails {
                Text("A logo, links and fresher hiring can be added once the database has been updated — run the fresher-hiring migration from the README.")
            }
        }
    }

    // MARK: - Other names

    /// Brands, a former name, the name it trades under. Searching any of them
    /// finds this company.
    private var otherNamesSection: some View {
        Section {
            ForEach(draft.alsoKnownAs, id: \.self) { name in
                HStack {
                    Text(name)
                        .foregroundStyle(.ink)
                    Spacer()
                    Button {
                        Haptics.tap()
                        draft.alsoKnownAs.removeAll { $0 == name }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Color.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(name)")
                }
            }
            HStack {
                TextField(draft.alsoKnownAs.isEmpty ? "Add a brand or former name" : "Add another name",
                          text: $newOtherName)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .otherName)
                    .submitLabel(.done)
                    .onSubmit(addOtherName)
                Button(action: addOtherName) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(pendingOtherName == nil ? Color.inkFaint : Color.clay)
                }
                .buttonStyle(.plain)
                .disabled(pendingOtherName == nil)
                .accessibilityLabel("Add name")
            }
        } header: {
            Text("Also known as")
        } footer: {
            Text("Searching any of these finds this company.")
        }
    }

    private func addOtherName() {
        guard let name = pendingOtherName else { return }
        Haptics.select()
        draft.alsoKnownAs.append(name)
        newOtherName = ""
        focus = .otherName
    }

    // MARK: - Logo and links

    private var linksSection: some View {
        Section {
            logoRow
            linkField("Website", text: $draft.website, prompt: "stripe.com", field: .website, next: .careers)
            linkField("Careers page", text: $draft.careersURL, prompt: "stripe.com/jobs", field: .careers, next: nil)
        } header: {
            Text("Logo and links")
        } footer: {
            let bad = finalDetails.invalidLinkFields
            if !bad.isEmpty {
                Text("\(ListFormatter.localizedString(byJoining: bad)) \(bad.count == 1 ? "isn't" : "aren't") a web address\(bad.contains("Logo") ? " (the logo needs an https link)" : "").")
                    .foregroundStyle(Color.danger)
            } else if let note = provenanceNote {
                Text(note)
            }
        }
    }

    /// "Website found via Wikidata. Careers page linked from its website."
    private var provenanceNote: String? {
        var parts: [String] = []
        if finalDetails.website == initial.trimmed.website, !finalDetails.website.isEmpty,
           let source = LinkProvenance.label(websiteSource) {
            parts.append("Website found via \(source).")
        }
        if finalDetails.careersURL == initial.trimmed.careersURL, !finalDetails.careersURL.isEmpty,
           let source = LinkProvenance.label(careersSource) {
            parts.append("Careers page found via \(source).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var logoURL: URL? {
        CompanyLink.url(draft.logoURL).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
    }

    private var logoRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                CompanyLogo(name: draft.name.isEmpty ? "?" : draft.name, url: logoURL, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Logo")
                        .font(.headline)
                        .foregroundStyle(.ink)
                    Text(logoNote ?? (logoURL == nil ? "None yet — the monogram is shown." : "The company's own icon, from its website."))
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button {
                    findLogo()
                } label: {
                    HStack(spacing: 6) {
                        if isFindingLogo {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkle.magnifyingglass")
                        }
                        Text(isFindingLogo ? "Looking…" : "Find on Website")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(.clay)
                .disabled(isFindingLogo || CompanyLink.url(draft.website) == nil)
                Spacer(minLength: 0)
                if !draft.logoURL.isEmpty {
                    Button("Remove", role: .destructive) {
                        Haptics.tap()
                        draft.logoURL = ""
                        logoNote = nil
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
            }
            TextField("Logo image link (https, PNG)", text: $draft.logoURL)
                .font(.footnote)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .focused($focus, equals: .logo)
                .foregroundStyle(.inkMuted)
        }
        .padding(.vertical, 4)
    }

    private func linkField(_ label: String, text: Binding<String>, prompt: String,
                           field: Field, next: Field?) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .submitLabel(next == nil ? .done : .next)
                .onSubmit { focus = next }
        }
    }

    // MARK: - Social links

    private var socialLinksSection: some View {
        Section {
            linkField("LinkedIn", text: socialLink(\.linkedIn), prompt: "linkedin.com/company/…",
                      field: .linkedIn, next: .x)
            linkField("X", text: socialLink(\.x), prompt: "x.com/…", field: .x, next: .facebook)
            linkField("Facebook", text: socialLink(\.facebook), prompt: "facebook.com/…",
                      field: .facebook, next: nil)
        } header: {
            HStack(spacing: 6) {
                Text("Social links")
                if !linksReady && !linksUnavailable { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if linksUnavailable {
                Text("Couldn't load them, so they can't be changed right now. The rest saves as usual.")
            } else {
                Text(companyID.flatMap { jobStore.companyLinks[$0]?.isImported } == true
                     ? "These came with a vault you imported. Saving keeps a copy in yours."
                     : "Sealed with your vault's key, so only you and anyone you've given its code and private key can see them.")
            }
        }
        .disabled(!linksReady)
        .task(id: companyID) { await loadLinks() }
    }

    /// A link as a text field edits it: an empty field is no link.
    private func socialLink(_ path: WritableKeyPath<KeyRing.CompanyLinks, String?>) -> Binding<String> {
        Binding(get: { draft.links[keyPath: path] ?? "" },
                set: { draft.links[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    /// The company's links, when the form opened before they'd loaded.
    private func loadLinks() async {
        guard let companyID, !linksReady else { return }
        if jobStore.companyLinks[companyID] == nil { await jobStore.loadCompanyLinks(companyID: companyID) }
        // Still none: the request failed, and the fields stay off.
        guard let loaded = jobStore.companyLinks[companyID]?.links else {
            linksUnavailable = true
            return
        }
        initial.links = loaded
        if draft.links.isEmpty { draft.links = loaded }
        linksReady = true
    }

    private func findLogo() {
        guard let site = CompanyLink.url(draft.website) else { return }
        Haptics.tap()
        isFindingLogo = true
        logoNote = nil
        Task {
            let found = await LogoFinder.find(on: site)
            isFindingLogo = false
            if let found {
                Haptics.success()
                draft.logoURL = found.absoluteString
                logoNote = "Found on \(CompanyLink.display(site))."
            } else {
                Haptics.failure()
                logoNote = "The website doesn't offer a PNG icon that's large and square enough."
            }
        }
    }

    // MARK: - Fresher hiring

    private var fresherSection: some View {
        Section {
            Toggle(isOn: $draft.isFresher.animation(Theme.Motion.snappy)) {
                Label("Hires freshers", systemImage: "graduationcap.fill")
            }
            if draft.isFresher {
                Toggle(isOn: $draft.isOpenNow) {
                    Label("Open to freshers now", systemImage: "dot.radiowaves.left.and.right")
                }
                Picker(selection: $draft.companyType) {
                    Text("Not set").tag("")
                    ForEach(CompanyType.known, id: \.self) { Text($0).tag($0) }
                    let current = draft.companyType.trimmingCharacters(in: .whitespaces)
                    if !current.isEmpty && !CompanyType.known.contains(current) {
                        Text(current).tag(draft.companyType)
                    }
                } label: {
                    Label("Type", systemImage: "building.2")
                }
                routesRows
                monthsRow
                batchesRow
                rolesRows
            }
        } header: {
            Text("Fresher hiring")
        } footer: {
            Text(draft.isFresher
                 ? "Shown on the company's screen. The Freshers filter in Companies lists every company marked here; its routes decide which route filter it's under."
                 : "Mark it to show it under the Freshers filter, with how it hires freshers.")
        }
    }

    /// The routes as a checklist, strongest first.
    @ViewBuilder
    private var routesRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hiring routes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
            ForEach(HiringRoute.ordered) { route in
                let on = draft.hiringRoutes.contains(route)
                Button {
                    Haptics.select()
                    if on { draft.hiringRoutes.remove(route) } else { draft.hiringRoutes.insert(route) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: route.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(on ? route.tint : Color.inkFaint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(route.title)
                                .font(.subheadline)
                                .foregroundStyle(.ink)
                            Text(route.detail)
                                .font(.caption2)
                                .foregroundStyle(.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(on ? Color.clay : Color.inkFaint)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(route.detail)
            }
        }
        .padding(.vertical, 4)
    }

    /// Stored in English, as the ledger writes them, whatever the phone's language.
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The months in "Sep, Dec", by their first three letters.
    private var selectedMonths: Set<String> {
        Set(draft.usuallyOpens.split(separator: ",").map {
            String($0.trimmingCharacters(in: .whitespaces).prefix(3)).capitalized
        }.filter(Self.months.contains))
    }

    private var monthsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usually opens")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
            WrappingHStack(spacing: 6, lineSpacing: 6) {
                ForEach(Self.months, id: \.self) { month in
                    let on = selectedMonths.contains(month)
                    Button {
                        Haptics.select()
                        var picked = selectedMonths
                        if on { picked.remove(month) } else { picked.insert(month) }
                        draft.usuallyOpens = Self.months.filter(picked.contains).joined(separator: ", ")
                    } label: {
                        Text(month)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(on ? Color.white : Color.ink)
                            .frame(minWidth: 40)
                            .padding(.vertical, 6)
                            .background {
                                if on {
                                    Capsule().fill(Color.clay)
                                } else {
                                    Capsule().strokeBorder(Color.hairline, lineWidth: 1)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var batchesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batches")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
            if !draft.batches.isEmpty {
                WrappingHStack(spacing: 6, lineSpacing: 6) {
                    ForEach(draft.batches, id: \.self) { batch in
                        Button {
                            Haptics.tap()
                            draft.batches.removeAll { $0 == batch }
                        } label: {
                            HStack(spacing: 4) {
                                Text(batch)
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.clay)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.clay.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove batch \(batch)")
                    }
                }
            }
            HStack {
                TextField("Add a graduation year, e.g. 2026", text: $newBatch)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .batch)
                    .onSubmit(addBatch)
                Button(action: addBatch) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(pendingBatch == nil ? Color.inkFaint : Color.clay)
                }
                .buttonStyle(.plain)
                .disabled(pendingBatch == nil)
                .accessibilityLabel("Add batch")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var rolesRows: some View {
        ForEach(draft.fresherRoles, id: \.self) { role in
            HStack {
                Text(role)
                    .foregroundStyle(.ink)
                Spacer()
                Button {
                    Haptics.tap()
                    draft.fresherRoles.removeAll { $0 == role }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(role)")
            }
        }
        HStack {
            TextField(draft.fresherRoles.isEmpty ? "Add a role, e.g. SDE-1" : "Add another role", text: $newRole)
                .textInputAutocapitalization(.words)
                .focused($focus, equals: .role)
                .submitLabel(.done)
                .onSubmit(addRole)
            Button(action: addRole) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(pendingRole == nil ? Color.inkFaint : Color.clay)
            }
            .buttonStyle(.plain)
            .disabled(pendingRole == nil)
            .accessibilityLabel("Add role")
        }
    }

    private func addBatch() {
        guard let year = pendingBatch else { return }
        Haptics.select()
        draft.batches = (draft.batches + [year]).sorted()
        newBatch = ""
    }

    private func addRole() {
        guard let role = pendingRole else { return }
        Haptics.select()
        draft.fresherRoles.append(role)
        newRole = ""
        focus = .role
    }

    // MARK: - Sources

    private func sourcesSection(_ companyID: String) -> some View {
        let sources = jobStore.sources[companyID]
        let package = StatedPackage(sources ?? [])
        return Section {
            NavigationLink {
                CompanySourcesView(companyID: companyID)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Color.clay)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sources and packages")
                            .foregroundStyle(.ink)
                        Text(sources.map { "\($0.count) on file\(package.headline.map { " · \($0)" } ?? "")" } ?? "Loading…")
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                    }
                }
            }
        } footer: {
            Text("Add, correct or invalidate the posts and write-ups behind this company's fresher hiring. Those changes save as you make them, for every user.")
        }
        .task(id: companyID) { await jobStore.loadSources(companyID: companyID) }
    }

    // MARK: - Mail domains

    private var domainsSection: some View {
        Section {
            ForEach(draft.domains, id: \.self) { domain in
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
                        draft.domains.removeAll { $0 == domain }
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
                                draft.domains.append(domain)
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
        for domain in finalDetails.domains where owners[domain] == nil {
            guard !Task.isCancelled else { return }
            guard let found = try? await jobStore.companies(forDomain: domain) else { continue }
            owners[domain] = found.filter { $0.id != companyID }.map(\.company)
        }
    }

    private func addPendingDomain() {
        guard let domain = pendingDomain else { return }
        Haptics.select()
        draft.domains.append(domain)
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
                details: company.details(links: jobStore.companyLinks[company.id]?.links),
                websiteSource: company.websiteSource,
                careersSource: company.careersSource,
                suggestedDomains: company.contactDomains,
                title: "Edit Company",
                confirmLabel: "Save"
            ) { details in
                Task { await jobStore.updateCompany(id: company.id, details: details) }
            }
        }
    }
}
