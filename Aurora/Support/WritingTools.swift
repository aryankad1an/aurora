import SwiftUI
import UIKit
import FoundationModels

/// The system's Writing Tools (Apple Intelligence) as the app's way of editing
/// text: the button opens Apple's own panel on the text being edited, and when
/// the panel closes having changed the text, `reviewsWritingTools` shows what
/// changed and asks whether to keep it.
enum WritingTools {
    /// Nil when Writing Tools can be used; otherwise why not, for the user.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to use this."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still getting ready. Try again in a little while."
        case .unavailable:
            "Apple Intelligence isn't available right now."
        }
    }

    /// Open Writing Tools on whichever text view has the keyboard. False when
    /// there's none to open it on.
    @MainActor
    @discardableResult
    static func present() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows }.flatMap { $0 }
        for window in windows {
            if let textView = window.descendants(of: UITextView.self).first(where: \.isFirstResponder) {
                textView.showWritingTools(textView)
                return true
            }
        }
        return false
    }
}

extension UIView {
    /// Every view below this one of a given type.
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
    }
}

// MARK: - Button

/// The sparkles button: Writing Tools on the text it sits beside.
struct WritingToolsButton: View {
    /// Puts the keyboard in the text, so Writing Tools has something to work on.
    var focusEditor: () -> Void
    @State private var message: String?

    var body: some View {
        Button {
            Haptics.tap()
            if let reason = WritingTools.unavailableReason {
                message = reason
                return
            }
            focusEditor()
            Task {
                // Long enough for the keyboard to arrive and take the text.
                try? await Task.sleep(for: .milliseconds(350))
                if !WritingTools.present() { message = "Tap in the text first, then try again." }
            }
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("Edit with Apple Intelligence")
        .accessibilityHint("Opens Writing Tools: proofread, rewrite, or describe a change")
        .messageAlert("Apple Intelligence", message: message) { message = nil }
    }
}

// MARK: - Watching

extension View {
    /// After Writing Tools changes this text, shows what changed and lets the user
    /// keep it or put the old text back. Applies to the `TextEditor` it's on, and
    /// also catches Writing Tools opened from the text's own selection menu.
    func reviewsWritingTools(text: Binding<String>, onKept: @escaping () -> Void = {}) -> some View {
        modifier(ReviewsWritingTools(text: text, onKept: onKept))
    }
}

private struct ReviewsWritingTools: ViewModifier {
    @Binding var text: String
    let onKept: () -> Void
    @State private var change: WritingToolsChange?

    func body(content: Content) -> some View {
        content
            .background { WritingToolsProbe { change = $0 } }
            .sheet(item: $change) { change in
                WritingToolsReviewSheet(change: change,
                                        onRevert: { text = change.before },
                                        onKeep: onKept)
            }
    }
}

/// An invisible view behind a text editor that finds the editor's `UITextView` and
/// samples it ten times a second for "is Writing Tools active".
private struct WritingToolsProbe: UIViewRepresentable {
    let onChange: (WritingToolsChange) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onTick = { [coordinator = context.coordinator] view in coordinator.tick(view) }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator {
        var onChange: (WritingToolsChange) -> Void
        private var tracker = WritingToolsTracker()
        private var seeded = false

        init(onChange: @escaping (WritingToolsChange) -> Void) { self.onChange = onChange }

        @MainActor
        func tick(_ probe: ProbeView) {
            guard let textView = Self.textView(behind: probe) else { return }
            if !seeded {
                tracker = WritingToolsTracker(text: textView.text)
                seeded = true
            }
            if let change = tracker.observe(isActive: textView.isWritingToolsActive, text: textView.text) {
                onChange(change)
            }
        }

        /// The text view this probe sits behind: the one in the same window that
        /// covers most of the probe's frame.
        @MainActor
        private static func textView(behind probe: ProbeView) -> UITextView? {
            guard let window = probe.window else { return nil }
            let area = probe.convert(probe.bounds, to: window)
            guard area.width > 0, area.height > 0 else { return nil }
            let areaSize = area.width * area.height
            var best: (view: UITextView, overlap: CGFloat)?
            for textView in window.descendants(of: UITextView.self) {
                let overlap = textView.convert(textView.bounds, to: window).intersection(area)
                guard !overlap.isNull else { continue }
                let size = overlap.width * overlap.height
                if size > areaSize * 0.6, size > (best?.overlap ?? 0) { best = (textView, size) }
            }
            return best?.view
        }
    }

    final class ProbeView: UIView {
        var onTick: (@MainActor (ProbeView) -> Void)?
        private var timer: Timer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            // `.common`, so it keeps sampling while the screen is being scrolled.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.onTick?(self) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        deinit { timer?.invalidate() }
    }
}
