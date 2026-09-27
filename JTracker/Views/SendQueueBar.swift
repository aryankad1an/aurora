import SwiftUI

/// The send queue's presence in the UI: a compact strip that rides above the tab
/// bar while mails go out, and reports the result when they're done.
///
/// It lives in the tab bar's accessory slot — the same shelf a music app uses for
/// its mini player — because that's the one place in iOS that means "something of
/// yours is still running" without covering the screen you're using. Sending is
/// no longer something you wait on, so it shouldn't own a screen.
struct SendQueueBar: View {
    @Environment(MailQueue.self) private var queue

    /// How long a clean result stays up before clearing itself. Failures don't
    /// auto-clear — those need to be read.
    private static let successLinger = Duration.seconds(5)

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            // "3 of 8" ticking up is the only motion on the shelf while a batch
            // runs — animated, it reads as progress rather than as a redraw.
            .animation(Theme.Motion.pop, value: queue.completed)

            Spacer(minLength: 4)

            trailingControl
        }
        .padding(.horizontal, 14)
        // A finished run's shelf says "Tap to dismiss", so the whole shelf is the
        // target — it used to be only the small × at its end.
        .contentShape(.rect)
        .onTapGesture {
            guard !queue.isRunning, queue.outcome != nil else { return }
            Haptics.tap(0.5)
            queue.acknowledge()
        }
        // The result is the one thing on this shelf the user is waiting for, and
        // by the time it lands they've usually navigated away from the screen
        // they sent from. Two tones so the answer arrives before the words are
        // read: the success chime for a clean run, the error buzz for a partial.
        .sensoryFeedback(trigger: queue.outcome?.failed.isEmpty) { _, clean -> SensoryFeedback? in
            switch clean {
            case .some(true): return .success
            case .some(false): return .error
            case .none: return nil
            }
        }
        .animation(Theme.Motion.bouncy, value: queue.isRunning)
        .task(id: queue.outcome?.failed.isEmpty) {
            // Only a fully successful run clears itself.
            guard let outcome = queue.outcome, outcome.failed.isEmpty else { return }
            try? await Task.sleep(for: Self.successLinger)
            guard !Task.isCancelled else { return }
            queue.acknowledge()
        }
    }

    @ViewBuilder
    private var icon: some View {
        if queue.isRunning {
            // Drawn by hand rather than with ProgressView: the circular style on
            // iOS ignores `value` and spins indeterminately, which would say
            // "working" while hiding how far along a long batch actually is.
            ZStack {
                Circle()
                    .stroke(Color.ink.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(queue.progress, 0.02))
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 21, height: 21)
            .animation(Theme.Motion.settle, value: queue.progress)
            .transition(LiquidMaterialize(scale: 0.5))
        } else if let outcome = queue.outcome {
            Image(systemName: outcome.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(outcome.failed.isEmpty ? Color.statusDone : Color.statusInvalid)
                // The tick replaces the progress ring in the same 21pt slot, so
                // it springs in rather than swapping — the run visibly finishes.
                .symbolEffect(.bounce, value: outcome.sent)
                .transition(LiquidMaterialize(scale: 0.4))
        }
    }

    private var title: String {
        if queue.isStopping { return "Stopping…" }
        if queue.isRunning { return "Sending mail" }
        guard let outcome = queue.outcome else { return "" }
        if outcome.failed.isEmpty {
            return outcome.sent == 1 ? "Mail sent" : "\(outcome.sent) mails sent"
        }
        return "\(outcome.sent) sent · \(outcome.failed.count) failed"
    }

    private var subtitle: String {
        if queue.isStopping {
            return "Finishing the mail already on its way"
        }
        if queue.isRunning {
            return "\(queue.completed) of \(queue.total) · keep the app open"
        }
        guard let outcome = queue.outcome, !outcome.failed.isEmpty else { return "Tap to dismiss" }
        if let reason = outcome.stoppedBecause { return reason }
        return "Couldn't reach \(outcome.failed.prefix(2).joined(separator: ", "))"
            + (outcome.failed.count > 2 ? " and \(outcome.failed.count - 2) more" : "")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if queue.isRunning {
            Button {
                // Stopping a run mid-flight is the destructive control here.
                Haptics.thud()
                queue.cancel()
            } label: {
                Text("Stop")
                    .font(.caption.weight(.semibold))
            }
            // Bordered, not glass: the shelf is already glass, and glass on glass
            // is two panes rendering (and trailing each other) at once.
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(queue.isStopping)
        } else if queue.outcome != nil {
            Button {
                Haptics.tap(0.5)
                queue.acknowledge()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.inkMuted)
            }
            .buttonStyle(BouncyPress(scale: 0.8))
        }
    }
}
