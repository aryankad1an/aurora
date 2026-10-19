import SwiftUI

/// One run of the Aurora Writer shortcut to check it answers. Held outside the
/// setup screen, whose own state doesn't survive the trip to Shortcuts.
@MainActor @Observable
final class ShortcutTest {
    enum State: Equatable {
        case idle, running, passed(String), failed(String)
    }
    private(set) var state = State.idle
    private var job: Task<Void, Never>?

    func run() {
        job?.cancel()
        state = .running
        job = Task {
            do {
                let answer = try await ShortcutsWriter.shared.ask("Reply with exactly one word: Ready",
                                                                  title: "Testing the shortcut")
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                Haptics.success()
                withAnimation {
                    state = .passed(trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed)
                    UserDefaults.standard.set(true, forKey: ShortcutsWriter.enabledKey)
                }
            } catch let failure as ShortcutsWriter.Failure {
                Haptics.warning()
                withAnimation { state = .failed(failure.message) }
            } catch {
                withAnimation { state = .idle }
            }
        }
    }

    func cancel() {
        job?.cancel()
    }
}

/// Setting up the Aurora Writer shortcut (see `ShortcutsWriter`): what it does,
/// how to make it, a test that runs it once, and the switch that sends writing
/// help to it.
struct ShortcutSetupView: View {
    let test: ShortcutTest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(ShortcutsWriter.enabledKey) private var isEnabled = false

    private static let steps: [String] = [
        "In Shortcuts, tap + to start a new shortcut. Name it exactly \(ShortcutsWriter.shortcutName).",
        "Add the Use Model action (search for “Use Model”, under Apple Intelligence).",
        "Tap the model in it and choose Cloud — or Private Cloud Compute, as older versions call it. Cloud Pro also works.",
        "Tap the request in it and choose Shortcut Input. Leave Follow Up off.",
        "If a “Receive … input” line appears at the top, tap it and allow Text only. If it offers a choice for when there's no input, pick Stop and Respond.",
        "Add Stop and Output, and set it to the Use Model action's Response. If it asks where to output when there's nowhere to, choose Do Nothing.",
        "Come back here and tap Test the Shortcut.",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Writing help can use Siri's larger cloud model through a shortcut of yours. Aurora opens Shortcuts to run it, the Dynamic Island shows it writing, and the answer comes back here for you to review.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkMuted)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.footnote.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Color.clay)
                                    .frame(minWidth: 24, minHeight: 24)
                                    .background(Color.clay.opacity(0.14), in: Circle())
                                Text(step)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                    .panel()

                    Button {
                        Haptics.tap()
                        openURL(ShortcutsWriter.newShortcutURL)
                    } label: {
                        Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .primaryButton()

                    Button {
                        Haptics.tap()
                        test.run()
                    } label: {
                        Label(test.state == .running ? "Waiting for the shortcut…" : "Test the Shortcut",
                              systemImage: "checkmark.seal")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .secondaryButton()
                    .disabled(test.state == .running)

                    testResult

                    Toggle(isOn: $isEnabled.animation(Theme.Motion.snappy)) {
                        Label("Write with the shortcut", systemImage: "sparkles")
                            .foregroundStyle(Color.ink)
                    }
                    .tint(Color.clay)
                    .padding(16)
                    .panel()

                    Text("If the shortcut doesn't answer, the smaller model on your iPhone writes instead, and says so. Shortcuts may ask the first time whether it can open Aurora: allow it.")
                        .font(.footnote)
                        .foregroundStyle(Color.inkMuted)
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .paperScreen()
            .navigationTitle("Aurora Writer Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { close() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Done")
                }
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test.state {
        case .idle, .running:
            EmptyView()
        case .passed(let answer):
            Label("It works. The shortcut answered “\(answer)”, and writing help now uses it.",
                  systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color.olive)
                .transition(.opacity)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color.danger)
                .transition(.opacity)
        }
    }

    private func close() {
        test.cancel()
        dismiss()
    }
}
