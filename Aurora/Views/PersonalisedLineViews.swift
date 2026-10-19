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

/// Where the line is written: a text box with Apple Intelligence behind the
/// sparkles button — to draft a line from notes or refine one — and its changes
/// shown for review before they're kept.
struct PersonalisedLineSheet: View {
    let company: String
    /// For drafting a line from scratch.
    var sector: String?

    @Environment(PersonalisedLineStore.self) private var lines
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var aiFlash = 0
    @State private var writingTools = WritingToolsTarget()
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
                        .reviewsWritingTools(text: $text, target: writingTools) { aiFlash += 1 }
                        .aiAppliedFlash(trigger: aiFlash, cornerRadius: 8,
                                        inset: EdgeInsets(top: -4, leading: -4, bottom: -4, trailing: -4))
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("e.g. I've been following your work on the Atlas launch.")
                                    .foregroundStyle(Color.inkFaint)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    // In the header, not the toolbar: a third bar item squeezes
                    // the company's name out of the title.
                    HStack {
                        Text("Your line")
                        Spacer()
                        WritingAssistButton(text: $text, subject: DraftSubject(company: company, sector: sector),
                                            writingTools: writingTools) { aiFlash += 1 }
                        .font(.body.weight(.semibold))
                        .textCase(nil)
                    }
                } footer: {
                    Text("Goes into mails to people at \(company) wherever a template has the Company line placeholder. Use the sparkles button to draft or refine it with Apple Intelligence. The line itself is kept on this device.")
                }
            }
            .navigationTitle(company)
            .navigationBarTitleDisplayMode(.inline)
            .discardableEdits(hasChanges)
            .toolbar {
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
