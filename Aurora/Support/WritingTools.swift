import SwiftUI
import UIKit
import FoundationModels

/// The system's Writing Tools (Apple Intelligence) as the app's way of editing
/// text: the button opens Apple's own panel on the text it's paired with, and
/// when the panel closes having changed the text, `reviewsWritingTools` shows
/// what changed and asks whether to keep it.
///
/// A screen pairs the two through a `WritingToolsTarget`:
///
///     @State private var writingTools = WritingToolsTarget()
///     WritingToolsButton(target: writingTools)
///     TextEditor(text: $body).reviewsWritingTools(text: $body, target: writingTools)
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
}

extension UIView {
    /// Every view below this one of a given type.
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        var found: [T] = []
        var stack = subviews
        while let view = stack.popLast() {
            if let match = view as? T { found.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}

// MARK: - Button

/// The text view a sparkles button opens Writing Tools on, found by the editor's
/// `reviewsWritingTools`. Held directly, not looked up as "whatever has the
/// keyboard" when tapped: with the Subject field focused, that opened Writing
/// Tools on the subject while the review watched the message.
@MainActor
final class WritingToolsTarget {
    fileprivate weak var textView: UITextView?
}

/// The sparkles button: Writing Tools on the text it's paired with.
struct WritingToolsButton: View {
    let target: WritingToolsTarget
    @State private var message: String?

    var body: some View {
        Button {
            Haptics.tap()
            if let reason = WritingTools.unavailableReason {
                message = reason
                return
            }
            guard let textView = target.textView else {
                message = "Tap in the text first, then try again."
                return
            }
            Task {
                // Writing Tools opens on the text view with the keyboard: put it
                // there, and give it a few frames to take it if it hadn't.
                if !textView.isFirstResponder { textView.becomeFirstResponder() }
                for _ in 0..<10 where !textView.isFirstResponder {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                textView.showWritingTools(textView)
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
    /// `target` is how a `WritingToolsButton` finds this text.
    func reviewsWritingTools(text: Binding<String>, target: WritingToolsTarget,
                             onKept: @escaping () -> Void = {}) -> some View {
        modifier(ReviewsWritingTools(text: text, target: target, onKept: onKept))
    }
}

private struct ReviewsWritingTools: ViewModifier {
    @Binding var text: String
    let target: WritingToolsTarget
    let onKept: () -> Void
    @State private var change: WritingToolsChange?

    func body(content: Content) -> some View {
        content
            .background { WritingToolsProbe(target: target) { change = $0 } }
            .sheet(item: $change) { change in
                WritingToolsReviewSheet(change: change,
                                        onRevert: { text = change.before },
                                        onKeep: onKept)
            }
    }
}

/// An invisible view behind a text editor that finds the editor's `UITextView` and
/// samples it ten times a second for "is Writing Tools active". The text view is
/// found once and held: searching the window's whole view tree on every sample
/// was a full traversal ten times a second for each editor on screen.
private struct WritingToolsProbe: UIViewRepresentable {
    let target: WritingToolsTarget
    let onChange: (WritingToolsChange) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onTick = { [coordinator = context.coordinator] view in coordinator.tick(view) }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.target = target
    }

    func makeCoordinator() -> Coordinator { Coordinator(target: target, onChange: onChange) }

    final class Coordinator {
        var onChange: (WritingToolsChange) -> Void
        var target: WritingToolsTarget
        private var tracker = WritingToolsTracker()
        private weak var textView: UITextView?

        init(target: WritingToolsTarget, onChange: @escaping (WritingToolsChange) -> Void) {
            self.target = target
            self.onChange = onChange
        }

        @MainActor
        func tick(_ probe: ProbeView) {
            // Looked for again only once the one held has left the window.
            if textView?.window == nil {
                guard let found = Self.textView(behind: probe) else { return }
                textView = found
                target.textView = found
                tracker = WritingToolsTracker(text: found.text)
            }
            guard let textView else { return }
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
            timer = nil
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
