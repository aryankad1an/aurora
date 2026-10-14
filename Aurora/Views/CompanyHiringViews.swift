import SwiftUI
import UIKit

// MARK: - Badges

/// The mark a fresher-hiring company wears on its logo: a cap on the reply
/// green, ringed in the card's paper so it reads as stuck to the tile's corner.
struct FresherBadge: View {
    var isOpenNow = false
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "graduationcap.fill")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(isOpenNow ? Color.statusDone : Color.slate, in: Circle())
            .overlay(Circle().strokeBorder(Color.paperRaised, lineWidth: 1.5))
            .accessibilityLabel(isOpenNow ? "Hiring freshers now" : "Hires freshers")
    }
}

extension View {
    /// The fresher badge on a logo's corner, when the company hires freshers.
    func fresherBadge(for job: Job, size: CGFloat = 16) -> some View {
        overlay(alignment: .bottomTrailing) {
            if job.isFresher {
                FresherBadge(isOpenNow: job.isOpenNow, size: size)
                    .offset(x: size * 0.3, y: size * 0.3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// A small labelled chip: a fact about a company or a source.
struct TagChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .inkMuted
    var filled = true

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if filled {
                Capsule().fill(tint.opacity(0.13))
            } else {
                Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1)
            }
        }
        .fixedSize()
    }
}

extension HiringRoute {
    /// Off-campus routes in the reply green (the ones that work from outside),
    /// campus and intern routes in slate, an unclear one in the muted ink.
    var tint: Color {
        switch category {
        case .offCampus: .statusDone
        case .campusOrIntern: .slate
        case .unclear: .inkMuted
        }
    }
}

// MARK: - The company screen's hiring card

/// Where to apply and what it pays: the company's website and careers page,
/// the package its valid sources state, the routes it hires freshers by, and
/// when. Every part is optional; the card shows what's known and offers to add
/// the links when they're missing.
struct HiringPanel: View {
    let job: Job
    let sources: [CompanySource]?
    var onEdit: () -> Void
    var onShowSources: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let package = StatedPackage(sources ?? [])
        // Side by side, until the text is too large for two tiles to share a row.
        let links = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        VStack(alignment: .leading, spacing: 14) {
            links {
                LinkTile(title: "Website", systemImage: "globe", url: job.websiteLink,
                         provenance: LinkProvenance.label(job.websiteSource), onAdd: onEdit)
                LinkTile(title: "Careers", systemImage: "briefcase.fill", url: job.careersLink,
                         provenance: LinkProvenance.label(job.careersSource), onAdd: onEdit)
            }

            if job.isFresher || !package.isEmpty {
                Divider().overlay(Color.hairline)
                packageRow(package)
            }

            if !job.hiringRoutes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "Hiring routes")
                    WrappingHStack(spacing: 6, lineSpacing: 6) {
                        ForEach(job.hiringRoutes) { route in
                            TagChip(text: route.title, systemImage: route.systemImage, tint: route.tint)
                                .accessibilityHint(route.detail)
                        }
                    }
                }
            }

            facts
        }
        .padding(16)
        .panel()
    }

    @ViewBuilder
    private func packageRow(_ package: StatedPackage) -> some View {
        Button(action: onShowSources) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.headline ?? "Not stated")
                        .font(.display(24))
                        .foregroundStyle(package.isEmpty ? Color.inkFaint : Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(packageCaption(package))
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if sources == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.inkFaint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stated package, \(package.headline ?? "not stated"). \(packageCaption(package))")
        .accessibilityHint("Shows the sources")
    }

    private func packageCaption(_ package: StatedPackage) -> String {
        guard let sources else { return "Stated package" }
        if package.isEmpty {
            return sources.isEmpty ? "Stated package · no sources yet" : "No valid source states a package"
        }
        let n = package.sources.count
        return "Stated package · from \(n) valid source\(n == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var facts: some View {
        let type = job.companyType?.trimmingCharacters(in: .whitespaces) ?? ""
        let opens = job.usuallyOpens?.trimmingCharacters(in: .whitespaces) ?? ""
        if !type.isEmpty || !opens.isEmpty || !job.batches.isEmpty || !job.fresherRoles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !type.isEmpty { FactRow(label: "Type", value: type, systemImage: "building.2") }
                if !opens.isEmpty { FactRow(label: "Usually opens", value: opens, systemImage: "calendar") }
                if !job.batches.isEmpty {
                    FactRow(label: "Batches", value: job.batches.joined(separator: " · "), systemImage: "graduationcap")
                }
                if !job.fresherRoles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Roles", systemImage: "person.text.rectangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.inkMuted)
                        WrappingHStack(spacing: 6, lineSpacing: 6) {
                            ForEach(job.fresherRoles, id: \.self) { role in
                                TagChip(text: role, tint: .ink, filled: false)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One fact: a muted label over its value.
private struct FactRow: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkMuted)
                .frame(minWidth: 112, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A link as a tile: what it is, where it goes. Opens in the browser; held, it
/// says where the link came from and offers to copy it. A missing link is a
/// dashed tile that opens the editor.
private struct LinkTile: View {
    let title: String
    let systemImage: String
    let url: URL?
    let provenance: String?
    var onAdd: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            Haptics.tap()
            if let url { openURL(url) } else { onAdd() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: url == nil ? "plus" : systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(url == nil ? Color.inkFaint : Color.clay)
                    .frame(width: 30, height: 30)
                    .background((url == nil ? Color.inkFaint : Color.clay).opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(url == nil ? Color.inkMuted : Color.ink)
                    Text(url.map(CompanyLink.display) ?? "Add")
                        .font(.caption)
                        .foregroundStyle(url == nil ? Color.inkFaint : Color.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.inkFaint)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                if url == nil {
                    shape.strokeBorder(Color.inkFaint.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    shape.fill(Color.paperSunken)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(CardPress())
        .contextMenu {
            if let url {
                // Where the link came from heads its actions.
                Section(provenance.map { "Found via \($0)" } ?? "") {
                    Button { openURL(url) } label: { Label("Open", systemImage: "safari") }
                    Button {
                        UIPasteboard.general.url = url
                        Haptics.success()
                    } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                }
            }
            Button(action: onAdd) { Label("Edit", systemImage: "pencil") }
        }
        .accessibilityLabel(url == nil ? "Add \(title.lowercased())" : "\(title), \(url.map(CompanyLink.display) ?? "")")
        .accessibilityHint(url == nil ? "Opens Edit Company" : (provenance.map { "Found via \($0). Opens in the browser." } ?? "Opens in the browser"))
    }
}

// MARK: - Sources

/// A preview of a company's sources on its screen: the three that matter most,
/// and the way to all of them.
struct SourcesPreview: View {
    let sources: [CompanySource]?
    var onShowAll: () -> Void
    var onAdd: () -> Void

    var body: some View {
        let valid = (sources ?? []).filter(\.isValid).sortedForDisplay()
        let invalid = (sources ?? []).count - valid.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.body)
                    .foregroundStyle(Color.clay)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sources")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    Text(subtitle(valid: valid.count, invalid: invalid))
                        .font(.caption)
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if sources == nil {
                    ProgressView().controlSize(.small)
                } else if (sources ?? []).isEmpty {
                    Button("Add", systemImage: "plus", action: onAdd)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .tint(.clay)
                } else {
                    Button(action: onShowAll) {
                        HStack(spacing: 3) {
                            Text("See All")
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(.clay)
                }
            }
            ForEach(valid.prefix(3)) { source in
                Divider().overlay(Color.hairline)
                SourceRowContent(source: source, compact: true)
                    .contentShape(.rect)
                    .onTapGesture(perform: onShowAll)
            }
        }
        .padding(14)
        .panel()
    }

    private func subtitle(valid: Int, invalid: Int) -> String {
        guard sources != nil else { return "Loading…" }
        if valid + invalid == 0 { return "Nothing on file yet" }
        let base = "\(valid) valid"
        return invalid == 0 ? base : base + " · \(invalid) invalid"
    }
}

/// One source: its route as a tile, the role, where and when it was seen, and
/// the package it states.
struct SourceRowContent: View {
    let source: CompanySource
    var compact = false

    private var details: String {
        [source.origin, source.dateLabel, source.location, source.batch.map { "Batch \($0)" }]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        let route = source.hiringRoute
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: route?.systemImage ?? "doc.text",
                     tint: source.isValid ? (route?.tint ?? Color.inkMuted) : Color.inkFaint,
                     size: compact ? 32 : Theme.Avatar.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .font(compact ? Font.subheadline.weight(.semibold) : Font.headline)
                    .foregroundStyle(source.isValid ? Color.ink : Color.inkMuted)
                    .strikethrough(!source.isValid, color: .inkFaint)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(compact ? 1 : 2)
                if !compact || source.package != nil || source.isOpenNow || !source.isValid {
                    HStack(spacing: 6) {
                        if !source.isValid {
                            InvalidPill()
                        } else if source.isOpenNow {
                            StatusChip(text: "Open now", systemImage: "dot.radiowaves.left.and.right", color: .statusDone)
                        }
                        if let package = source.package {
                            StatusChip(text: package, systemImage: "indianrupeesign", color: source.isValid ? Color.clay : Color.inkFaint)
                        }
                        if !compact, let route {
                            StatusChip(text: route.title, systemImage: route.systemImage, color: .inkMuted)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if source.link != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.inkFaint)
                    .padding(.top, 4)
            }
        }
        .opacity(source.isValid ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }
}

/// Every source filed under a company: the valid ones, or the ones ruled out,
/// one list at a time, as a company's contacts are. A tap opens the source;
/// a swipe or a hold marks it invalid — for everyone, with a moment to undo.
struct CompanySourcesView: View {
    let companyID: String
    @Environment(JobStore.self) private var jobStore
    @Environment(\.openURL) private var openURL

    @State private var group = SourceGroup.valid
    @State private var searchText = ""
    @State private var editing: CompanySource?
    @State private var pendingDelete: CompanySource?

    private enum SourceGroup: Hashable { case valid, invalid }

    private var job: Job? { jobStore.company(id: companyID) }
    /// Nil until they've loaded.
    private var loaded: [CompanySource]? { jobStore.sources[companyID] }

    var body: some View {
        let all = loaded ?? []
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? all : all.filter { $0.matches(query) }
        let valid = matching.filter(\.isValid).sortedForDisplay()
        let invalid = matching.filter { !$0.isValid }.sortedForDisplay()
        let shown = (all.contains { !$0.isValid } && group == .invalid) ? invalid : valid
        let package = StatedPackage(all)

        List {
            Section {
                summary(package: package, total: all.count)
                    .cardRow(top: 8, bottom: 6)
                if all.contains(where: { !$0.isValid }) {
                    SegmentedSelector(segments: [
                        (.valid, "Valid \(valid.count)"),
                        (.invalid, "Invalid \(invalid.count)")
                    ], selection: $group)
                        .cardRow(top: 4, bottom: 6)
                }
            }
            Section {
                if loaded == nil {
                    LoadingRow().cardRow()
                } else if SupabaseAPI.sourcesTableMissing {
                    InlineEmptyState(title: "Sources need a database update",
                                     systemImage: "externaldrive.badge.exclamationmark",
                                     message: "Run the fresher-hiring migration from the README in the Supabase SQL editor.")
                        .cardRow()
                } else if shown.isEmpty {
                    InlineEmptyState(title: query.isEmpty ? (group == .invalid ? "No invalid sources" : "No sources yet") : "No matches",
                                     systemImage: query.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass",
                                     message: query.isEmpty ? "Add a job post, an offer write-up or a placement page that shows this company hiring freshers." : "No source mentions “\(query)”.")
                        .cardRow()
                } else {
                    ForEach(shown) { source in
                        row(source)
                    }
                    if group == .invalid {
                        Text("Wrong, dead or not about freshers. Invalid sources don't count toward the stated package. Swipe right to put one back.")
                            .font(.footnote)
                            .foregroundStyle(.inkMuted)
                            .padding(.horizontal, 4)
                            .cardRow(top: 4, bottom: 12)
                    }
                }
            }
        }
        .cardList()
        .paperScreen()
        .animation(Theme.Motion.snappy, value: shown.map(\.id))
        .animation(nil, value: searchText)
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search roles, places, sources")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Source", systemImage: "plus") {
                    editing = CompanySource(companyID: companyID)
                }
                .disabled(SupabaseAPI.sourcesTableMissing)
            }
        }
        .refreshable { await jobStore.loadSources(companyID: companyID) }
        .task(id: companyID) { await jobStore.loadSources(companyID: companyID) }
        .sheet(item: $editing) { source in
            SourceEditorView(source: source)
        }
        .uniformDeleteAlert(
            item: $pendingDelete,
            title: { _ in "Delete this source?" },
            message: "It's removed for every user. Marking it invalid keeps it on record instead. This can't be undone."
        ) { source in
            Task { await jobStore.deleteSources([source]) }
        }
        .undoBanner()
    }

    private func summary(package: StatedPackage, total: Int) -> some View {
        HStack(spacing: 12) {
            if let job {
                CompanyLogo(job: job, size: Theme.Avatar.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(package.headline ?? "No package stated")
                    .font(.display(20))
                    .foregroundStyle(package.isEmpty ? Color.inkFaint : Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(package.isEmpty
                     ? "\(total) source\(total == 1 ? "" : "s") on file"
                     : "Stated package, from \(package.sources.count) of \(total) source\(total == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .panel()
    }

    @ViewBuilder
    private func row(_ source: CompanySource) -> some View {
        Button {
            if let link = source.link {
                openURL(link)
            } else {
                editing = source
            }
        } label: {
            SourceRowContent(source: source)
                .padding(12)
                .panelAccented(source.isValid ? (source.isOpenNow ? Color.statusDone : nil) : Color.inkFaint)
        }
        .buttonStyle(CardPress())
        .cardRow()
        .swipeActions(edge: .leading) {
            Button {
                Haptics.tap()
                Task { await jobStore.setSourceValidity([source], isValid: !source.isValid) }
            } label: {
                Label(source.isValid ? "Invalid" : "Valid",
                      systemImage: source.isValid ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            }
            .tint(source.isValid ? Color.statusInvalid : Color.statusDone)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Haptics.warning()
                pendingDelete = source
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editing = source
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.clay)
        }
        .contextMenu {
            if let link = source.link {
                Button { openURL(link) } label: { Label("Open Source", systemImage: "safari") }
            }
            if let proof = source.proofLink {
                Button { openURL(proof) } label: { Label("Open Snapshot", systemImage: "clock.arrow.circlepath") }
            }
            if let link = source.link {
                Button {
                    UIPasteboard.general.url = link
                    Haptics.success()
                } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            }
            Button { editing = source } label: { Label("Edit", systemImage: "pencil") }
            Button {
                Task { await jobStore.setSourceValidity([source], isValid: !source.isValid) }
            } label: {
                Label(source.isValid ? "Mark Invalid" : "Mark Valid",
                      systemImage: source.isValid ? "exclamationmark.triangle" : "checkmark.circle")
            }
            Divider()
            Button(role: .destructive) {
                Haptics.warning()
                pendingDelete = source
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// Add a source, or correct one: what it shows, where it was found, and the
/// package it states. Saved for every user.
struct SourceEditorView: View {
    let original: CompanySource
    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CompanySource
    @State private var url: String
    @State private var proofURL: String
    @State private var package: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var isSaving = false
    /// The package as first shown, so an untouched one is saved exactly as it was.
    private let initialPackage: String

    init(source: CompanySource) {
        original = source
        let package = source.packageLPA.map { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) } ?? ""
        initialPackage = package
        _draft = State(initialValue: source)
        _url = State(initialValue: source.url ?? "")
        _proofURL = State(initialValue: source.proofURL ?? "")
        _package = State(initialValue: package)
        _hasDate = State(initialValue: source.date != nil)
        _date = State(initialValue: source.date ?? Date())
    }

    /// A link field left as it was keeps its exact text; a changed one is
    /// tidied ("stripe.com/jobs" → "https://stripe.com/jobs").
    private func link(_ text: String, was original: String?) -> String? {
        text == (original ?? "") ? original : CompanyLink.normalized(text)
    }

    private func isUnchanged(_ text: String, _ original: String?) -> Bool {
        text == (original ?? "")
    }

    private var isNew: Bool { original.id.isEmpty }

    /// The package typed, as a number; nil when empty or not one.
    private var packageValue: Double? {
        let text = package.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return text.isEmpty ? nil : Double(text)
    }

    private var problems: [String] {
        var out: [String] = []
        if !isUnchanged(url, original.url), !url.trimmingCharacters(in: .whitespaces).isEmpty, CompanyLink.url(url) == nil {
            out.append("The link isn't a web address.")
        }
        if !isUnchanged(proofURL, original.proofURL), !proofURL.trimmingCharacters(in: .whitespaces).isEmpty,
           CompanyLink.url(proofURL) == nil {
            out.append("The snapshot link isn't a web address.")
        }
        if package != initialPackage, !package.trimmingCharacters(in: .whitespaces).isEmpty,
           packageValue == nil || packageValue! <= 0 || packageValue! > 500 {
            out.append("The package should be a number of lakhs a year, like 12 or 16.5.")
        }
        return out
    }

    /// The source as it would be saved.
    private var result: CompanySource {
        var s = draft
        s.url = link(url, was: original.url)
        s.proofURL = link(proofURL, was: original.proofURL)
        s.packageLPA = package == initialPackage ? original.packageLPA : packageValue
        if !hasDate {
            s.postedOn = nil
        } else if let old = original.date, Calendar.current.isDate(old, inSameDayAs: date) {
            s.postedOn = original.postedOn  // unchanged: a month-only date stays one
        } else {
            s.postedOn = PostedDate.string(from: date)
        }
        return s
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section("What it shows") {
                    Picker("Route", selection: $draft.route) {
                        ForEach(HiringRoute.ordered) { route in
                            Label(route.title, systemImage: route.systemImage).tag(route.rawValue)
                        }
                        if HiringRoute(rawValue: draft.route) == nil {
                            Text(draft.route).tag(draft.route)
                        }
                    }
                    TextField("Role (e.g. SDE-1)", text: text(\.role))
                        .textInputAutocapitalization(.words)
                    TextField("Location", text: text(\.location))
                        .textInputAutocapitalization(.words)
                    TextField("Batch (e.g. 2025, 2026)", text: text(\.batch))
                        .keyboardType(.numbersAndPunctuation)
                    Toggle("Open now", isOn: $draft.isOpenNow)
                }
                Section {
                    HStack {
                        Text("₹")
                            .foregroundStyle(.inkMuted)
                        TextField("Package", text: $package)
                            .keyboardType(.decimalPad)
                        Text("LPA")
                            .foregroundStyle(.inkMuted)
                    }
                    TextField("As written, if a range (e.g. ₹4–4.5L)", text: text(\.packageText))
                } header: {
                    Text("Stated package")
                } footer: {
                    Text("Lakh rupees a year. Only valid sources count toward the company's stated package.")
                }
                Section {
                    TextField("Link to the post or write-up", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Where it was found (e.g. LinkedIn post)", text: text(\.sourceLabel))
                    Toggle("Date known", isOn: $hasDate.animation(Theme.Motion.snappy))
                    if hasDate {
                        DatePicker("Posted", selection: $date, in: ...Date(), displayedComponents: .date)
                    }
                    TextField("Snapshot link (optional)", text: $proofURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("Source")
                } footer: {
                    if !problems.isEmpty {
                        Text(problems.joined(separator: " "))
                            .foregroundStyle(Color.danger)
                    } else if let code = original.sourceCode, !code.isEmpty {
                        Text("From the Fresher Hiring Ledger. Your edits are kept if the ledger is imported again.")
                    }
                }
                if !isNew {
                    Section {
                        Button(original.isValid ? "Mark Invalid" : "Mark Valid",
                               systemImage: original.isValid ? "exclamationmark.triangle" : "checkmark.circle") {
                            Task {
                                await jobStore.setSourceValidity([original], isValid: !original.isValid)
                                dismiss()
                            }
                        }
                        .tint(original.isValid ? Color.statusInvalid : Color.statusDone)
                    } footer: {
                        Text("An invalid source stays on record but no longer counts, for every user.")
                    }
                }
            }
            .navigationTitle(isNew ? "New Source" : "Edit Source")
            .navigationBarTitleDisplayMode(.inline)
            .discardableEdits(result != original)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(isNew ? "Add" : "Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!problems.isEmpty || result == original)
                    }
                }
            }
        }
    }

    /// A binding to one of the source's optional text fields, as plain text.
    private func text(_ key: WritableKeyPath<CompanySource, String?>) -> Binding<String> {
        Binding { draft[keyPath: key] ?? "" } set: { draft[keyPath: key] = $0 }
    }

    /// Closes only once the write lands; a failure keeps what was typed.
    private func save() {
        isSaving = true
        Task {
            let saved = await jobStore.saveSource(result)
            isSaving = false
            if saved {
                Haptics.success()
                dismiss()
            } else {
                Haptics.failure()
            }
        }
    }
}
