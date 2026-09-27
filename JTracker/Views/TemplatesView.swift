import SwiftUI

/// The Templates tab: your reusable mails, each shown the way it reads.
///
/// A card is the template at a glance — its name, whether it's ready to send
/// (the same checks the editor runs, against your profile), the subject, the
/// opening lines with every placeholder lit up, and which placeholders it fills.
/// Tap to edit; hold for Duplicate, Select and Delete; swipe to delete; drag two
/// fingers down the cards to select several.
struct TemplatesView: View {
    @Environment(TemplateStore.self) private var store
    @Environment(ProfileStore.self) private var profileStore

    @State private var isAdding = false
    @State private var editingTemplate: MailTemplate?
    @State private var selection = ListSelection<MailTemplate.ID>()
    @State private var confirmingDelete = false
    @State private var pendingDelete: MailTemplate?
    @State private var searchText = ""

    /// Templates matching the search, by name, subject, or body — the body counts
    /// because "the one that mentions the referral" is how you actually remember
    /// a template you wrote weeks ago.
    private var filtered: [MailTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.templates }
        return store.templates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.subject.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let rows = filtered
        return NavigationStack {
            Group {
                if store.templates.isEmpty {
                    if store.isLoading { LoadingState() } else { emptyState }
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(selection: $selection.ids) {
                        ForEach(rows) { template in
                            templateCard(template)
                        }
                    }
                    .cardList()
                    .listRows(selection) { id in
                        editingTemplate = store.templates.first { $0.id == id }
                    } menu: { rowMenu($0) }
                    // Templates are per-account, not per-device — pull to sync in
                    // whatever another of the user's signed-in clients has saved.
                    .refreshable { await store.refresh() }
                }
            }
            .paperScreen()
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search templates")
            // Writing a template is what this screen is for, so it's the bar's
            // verb rather than an item in the menu.
            .topBarActions(
                TopBarPrimary(title: "New Template", systemImage: "plus") { isAdding = true },
                isHidden: selection.isSelecting
            ) {
                Button { selection.enter() } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(store.templates.isEmpty)
            }
            .selectionActions(
                selection,
                all: rows.map(\.id),
                noun: SelectionNoun(singular: "template", plural: "templates"),
                confirmingDelete: $confirmingDelete,
                onDelete: deleteSelected
            )
            .uniformDeleteAlert(
                item: $pendingDelete,
                title: { "Delete “\($0.name)”?" },
                message: "The template is removed from every device you're signed in on. Mails already sent aren't affected."
            ) { template in
                Task { await store.delete([template]) }
            }
            .sheet(isPresented: $isAdding) {
                TemplateEditorView(existing: nil) { new in
                    Task { await store.save(new) }
                }
            }
            .sheet(item: $editingTemplate) { template in
                TemplateEditorView(existing: template) { updated in
                    Task { await store.save(updated) }
                }
            }
        }
    }

    private func templateCard(_ template: MailTemplate) -> some View {
        TemplateCard(template: template,
                     status: TemplateStatus(template: template, profile: profileStore.profile))
            .swipeActions(edge: .trailing) {
                if !selection.isSelecting {
                    Button(role: .destructive) {
                        Haptics.warning()
                        pendingDelete = template
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Haptics.tap()
                        Task { await store.duplicate(template) }
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .tint(.slate)
                }
            }
            .cardRow(top: 6, bottom: 6)
    }

    /// A held card's menu — or, while selecting, the menu for everything ticked.
    /// It used to sit on the card itself, alongside a hold-to-select gesture of
    /// the same length: one hold both lifted the menu and started the selection.
    @ViewBuilder
    private func rowMenu(_ ids: Set<MailTemplate.ID>) -> some View {
        let templates = store.templates.filter { ids.contains($0.id) }
        if templates.count == 1, let template = templates.first {
            Button("Edit", systemImage: "pencil") { editingTemplate = template }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                Task { await store.duplicate(template) }
            }
        }
        if !templates.isEmpty {
            if !selection.isSelecting {
                Button("Select", systemImage: "checkmark.circle") { selection.begin(with: ids) }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                Haptics.warning()
                if templates.count == 1 {
                    pendingDelete = templates.first
                } else {
                    confirmingDelete = true
                }
            }
        }
    }

    private func deleteSelected() {
        Haptics.thud()
        let doomed = store.templates.filter { selection.contains($0.id) }
        selection.exit()
        Task { await store.delete(doomed) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No templates yet", systemImage: "doc.text")
        } description: {
            Text("A template is a mail you write once. Placeholders like {Receiver-Name} fill in per contact when you send.")
        } actions: {
            VStack(spacing: 10) {
                Button {
                    isAdding = true
                } label: {
                    Label("New Template", systemImage: "plus")
                }
                .primaryButton()
                Button {
                    Task { await store.save(.starter) }
                } label: {
                    Label("Start from an example", systemImage: "sparkles")
                }
                .secondaryButton()
            }
        }
    }
}

// MARK: - Status

/// Whether a template is ready to send, from the same checks the editor runs.
/// Recipients aren't consulted here — that needs the whole catalog, and belongs
/// to the editor's full report.
private struct TemplateStatus {
    let errors: Int
    let warnings: Int

    init(template: MailTemplate, profile: Profile) {
        let findings = TemplateDiagnostics.analyze(subject: template.subject, content: template.content,
                                                   profile: profile)
        errors = findings.filter { $0.severity == .error }.count
        warnings = findings.count - errors
    }

    var chip: StatusChip {
        if errors > 0 {
            return StatusChip(text: "\(errors) to fix", systemImage: "exclamationmark.octagon.fill", color: .danger)
        }
        if warnings > 0 {
            return StatusChip(text: "\(warnings) to check", systemImage: "exclamationmark.triangle.fill", color: .kraft)
        }
        return StatusChip(text: "Ready", systemImage: "checkmark.circle.fill", color: .olive)
    }
}

// MARK: - Card

/// Every line has a fixed allowance — one for the name, one for the subject,
/// three (reserved even when the body is shorter) for the opening, one for the
/// placeholders — so every card in the list is the same height.
private struct TemplateCard: View {
    let template: MailTemplate
    let status: TemplateStatus

    private var placeholders: [MailPlaceholder] {
        let text = template.subject + template.content
        return MailPlaceholder.allCases.filter { text.contains($0.token) }
    }

    private var wordCount: Int {
        template.content.split { $0.isWhitespace || $0.isNewline }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.body)
                    .foregroundStyle(.clay)
                    .frame(width: 34, height: 34)
                    .background(Color.clay.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.display(18))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text(template.subject.isEmpty
                         ? AttributedString("No subject")
                         : Self.highlighted(template.subject, font: .subheadline.weight(.medium)))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(template.subject.isEmpty ? Color.inkFaint : Color.inkMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                status.chip
            }

            // The opening, as it reads, with its placeholders lit up.
            Text(Self.highlighted(template.content.isEmpty ? "Empty template" : template.content,
                                  font: .callout.weight(.semibold)))
                .font(.callout)
                .foregroundStyle(Color.ink.opacity(0.82))
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.paperSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(alignment: .center, spacing: 8) {
                if placeholders.isEmpty {
                    Text("No placeholders")
                        .font(.caption)
                        .foregroundStyle(.inkFaint)
                } else {
                    // One line, never wrapping: as many chips as fit, then a
                    // "+N" for the rest. Wrapping made a placeholder-heavy
                    // template a card taller than its neighbours.
                    ViewThatFits(in: .horizontal) {
                        ForEach((0...placeholders.count).reversed(), id: \.self) { shown in
                            placeholderChips(shown)
                        }
                    }
                }
                Spacer(minLength: 4)
                Text("\(wordCount) words")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.inkFaint)
                    .fixedSize()
            }
        }
        .padding(14)
        .panel()
    }

    private func placeholderChips(_ shown: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(placeholders.prefix(shown)) { placeholder in
                Text(placeholder.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.slate)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.slate.opacity(0.14), in: Capsule())
            }
            if shown < placeholders.count {
                Text("+\(placeholders.count - shown)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.inkMuted)
            }
        }
        .fixedSize()
    }

    /// The body with each placeholder token coloured clay and set semibold, and
    /// line breaks folded to spaces so three lines show three lines of prose.
    private static func highlighted(_ content: String, font: Font) -> AttributedString {
        var result = AttributedString(content.replacingOccurrences(of: "\n", with: " "))
        for placeholder in MailPlaceholder.allCases {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result[searchRange].range(of: placeholder.token) {
                result[range].foregroundColor = .clay
                result[range].font = font
                searchRange = range.upperBound..<result.endIndex
            }
        }
        return result
    }
}

extension MailTemplate {
    /// A worked example for an empty account: a short, specific cold mail that
    /// shows every kind of placeholder in use.
    static var starter: MailTemplate {
        MailTemplate(
            name: "Intro — referral ask",
            subject: "{Sender-Position} at {Sender-College} — quick question about {Receiver-Company}",
            content: """
            Hi {Receiver-Name},

            I'm {Sender-Name}, a {Sender-Position} at {Sender-College}. I've been following {Receiver-Company}'s work and would love to be considered for an internship on your team.

            My resume is here: {Resume-Link}. Would you be open to a short chat, or pointing me to the right person?

            Thanks for your time,
            {Sender-Name}
            """
        )
    }
}

#Preview {
    TemplatesView()
        .environment(TemplateStore())
        .environment(ProfileStore())
}
