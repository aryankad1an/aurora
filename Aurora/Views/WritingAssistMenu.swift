import SwiftUI

/// What the assistant is told about a company when asked to write a line for it.
struct DraftSubject {
    let company: String
    let sector: String?
    let website: String?
}

/// The sparkles button that offers on-device Apple Intelligence writing help
/// (Foundation Models) for the text it is bound to: proofread, rewrite, change
/// tone, shorten or expand — and, when given a `subject`, write a first draft.
/// Each change can be undone from the same menu until the text is edited.
struct WritingAssistMenu: View {
    @Binding var text: String
    var subject: DraftSubject?

    @State private var assistant = WritingAssistant()
    /// What the last AI change produced, to tell whether the text has since
    /// been edited by hand (after which Undo would throw those edits away).
    @State private var applied: String?

    var body: some View {
        let unavailable = WritingAssistant.unavailableReason
        Menu {
            if let unavailable {
                Button(unavailable) {}.disabled(true)
            } else {
                if let subject {
                    Button {
                        run { await assistant.draft(company: subject.company, sector: subject.sector,
                                                    website: subject.website, replacing: text) }
                    } label: {
                        Label(text.isEmpty ? "Write one for me" : "Write a new one", systemImage: "wand.and.stars")
                    }
                }
                ForEach(WritingAction.allCases) { action in
                    Button {
                        run { await assistant.apply(action, to: text) }
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
                if assistant.previous != nil {
                    Divider()
                    Button {
                        if let old = assistant.undo() {
                            Haptics.tap()
                            text = old
                            applied = nil
                        }
                    } label: {
                        Label("Undo last change", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        } label: {
            if assistant.isWorking {
                ProgressView()
            } else {
                Image(systemName: "sparkles")
            }
        }
        .disabled(assistant.isWorking)
        .accessibilityLabel("Writing help")
        .accessibilityHint("Apple Intelligence: proofread, rewrite, change tone")
        .onChange(of: text) { _, now in
            if assistant.previous != nil, now != applied { assistant.forgetUndo() }
        }
        .messageAlert("Apple Intelligence", message: assistant.failure) { assistant.failure = nil }
    }

    private func run(_ work: @escaping () async -> String?) {
        Haptics.tap()
        Task {
            if let result = await work() {
                applied = result
                withAnimation(Theme.Motion.snappy) { text = result }
                Haptics.success()
            } else if assistant.failure != nil {
                Haptics.warning()
            }
        }
    }
}
