import SwiftUI

/// The user's personalised line for a company, on the company's page: what
/// `{Company-Personalised}` writes into mails to people there. Tap to write or
/// change it.
struct PersonalisedLineCard: View {
    let company: String
    let onEdit: () -> Void
    @Environment(PersonalisedLineStore.self) private var lines

    var body: some View {
        let line = lines.line(for: company)
        Button {
            Haptics.press()
            onEdit()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("Your personalised line", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(Color.inkMuted)
                    Spacer(minLength: 0)
                    Image(systemName: line.isEmpty ? "plus" : "pencil")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.clay)
                }
                if line.isEmpty {
                    Text("Add a sentence about \(company). It goes into mails to people here wherever a template has the Company line placeholder.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkFaint)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .panel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.isEmpty ? "Add a personalised line for \(company)" : "Personalised line for \(company): \(line)")
        .accessibilityHint("Opens the editor")
    }
}

/// Where the line is written: a text box with Apple Intelligence writing help
/// (on-device, via Foundation Models) in the toolbar, and the system's own
/// Writing Tools on the text itself.
struct PersonalisedLineSheet: View {
    let company: String
    let sector: String?
    let website: String?

    @Environment(PersonalisedLineStore.self) private var lines
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var hasChanges: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != saved }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    TextEditor(text: $text)
                        .writingToolsBehavior(.complete)
                        .focused($focused)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("e.g. I've been following your work on the Atlas launch.")
                                    .foregroundStyle(Color.inkFaint)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } footer: {
                    Text("Goes into mails to people at \(company) wherever a template has the Company line placeholder. Use the sparkles button to draft or refine it with Apple Intelligence. It stays on this device.")
                }
            }
            .navigationTitle(company)
            .navigationBarTitleDisplayMode(.inline)
            .discardableEdits(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    WritingAssistMenu(text: $text,
                                      subject: DraftSubject(company: company, sector: sector, website: website))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.success()
                        lines.set(text, for: company)
                        dismiss()
                    }
                    .disabled(!hasChanges)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                saved = lines.line(for: company)
                text = saved
                if saved.isEmpty { focused = true }
            }
        }
    }
}
