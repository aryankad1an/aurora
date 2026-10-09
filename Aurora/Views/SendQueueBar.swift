import SwiftUI

/// The mail queue's presence in the UI: a compact strip that rides above the tab
/// bar whenever the queue has something to say — mail going out, a run's
/// result, a batch paused or due, the next one scheduled. Tapping it opens the
/// queue — that's all a tap on it does; nothing on it clears anything.
///
/// It lives in the tab bar's accessory slot — the same shelf a music app uses for
/// its mini player — because that's the one place in iOS that means "something of
/// yours is still running" without covering the screen you're using. Sending is
/// no longer something you wait on, so it shouldn't own a screen.
struct SendQueueBar: View {
    @Environment(MailQueue.self) private var queue
    let onOpen: () -> Void

    /// How long a clean result stays up before clearing itself. Failures don't
    /// auto-clear — those need to be read.
    private static let successLinger = Duration.seconds(5)

    private enum Mode {
        case sending, result(MailQueue.Outcome), due(MailBatch), paused([MailBatch]), scheduled(MailBatch), idle
    }

    /// What matters most right now, in that order.
    private var mode: Mode {
        if queue.isRunning { return .sending }
        if let outcome = queue.outcome { return .result(outcome) }
        if let due = queue.readyBatch { return .due(due) }
        let paused = queue.pausedBatches
        if !paused.isEmpty { return .paused(paused) }
        if let next = queue.nextScheduled { return .scheduled(next) }
        return .idle
    }

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
        .contentShape(.rect)
        .onTapGesture {
            Haptics.tap(0.5)
            onOpen()
        }
        // The result is the one thing on this shelf the user is waiting for, and
        // by the time it lands they've usually navigated away from the screen
        // they sent from. Two tones so the answer arrives before the words are
        // read: the success chime for a clean run, the error buzz for a partial.
        .sensoryFeedback(trigger: queue.outcome.map { $0.failed.isEmpty && !$0.isPaused }) { _, clean -> SensoryFeedback? in
            switch clean {
            case .some(true): return .success
            case .some(false): return .error
            case .none: return nil
            }
        }
        .animation(Theme.Motion.bouncy, value: queue.isRunning)
        .task(id: queue.outcome.map { $0.failed.isEmpty && !$0.isPaused }) {
            // Only a fully successful run clears itself.
            guard let outcome = queue.outcome, outcome.failed.isEmpty, !outcome.isPaused else { return }
            try? await Task.sleep(for: Self.successLinger)
            guard !Task.isCancelled else { return }
            queue.acknowledge()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch mode {
        case .sending:
            // Drawn by hand rather than with ProgressView: the circular style on
            // iOS ignores `value` and spins indeterminately, which would say
            // "working" while hiding how far along a long batch actually is.
            ZStack {
                Circle()
                    .stroke(Color.ink.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(queue.progress, 0.02))
                    .stroke(Color.clay,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 21, height: 21)
            .animation(Theme.Motion.settle, value: queue.progress)
            .transition(LiquidMaterialize(scale: 0.5))
        case .result(let outcome):
            let clean = outcome.failed.isEmpty && !outcome.isPaused
            Image(systemName: clean ? "checkmark.circle.fill"
                  : outcome.isPaused ? "pause.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(clean ? Color.statusDone : outcome.isPaused ? Color.kraft : Color.statusInvalid)
                // The tick replaces the progress ring in the same 21pt slot, so
                // it springs in rather than swapping — the run visibly finishes.
                .symbolEffect(.bounce, value: outcome.sent)
                .transition(LiquidMaterialize(scale: 0.4))
        case .due:
            Image(systemName: "bell.badge.fill")
                .font(.title3)
                .foregroundStyle(.clay)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(.kraft)
        case .scheduled:
            Image(systemName: "clock.fill")
                .font(.title3)
                .foregroundStyle(.statusWaiting)
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch mode {
        case .sending:
            if queue.cooldown != nil { return "Waiting on Gmail" }
            return queue.isStopping ? "Pausing…" : "Sending mail"
        case .result(let outcome):
            if outcome.isPaused { return "\(outcome.sent) sent · paused" }
            if outcome.failed.isEmpty {
                return outcome.sent == 1 ? "Mail sent" : "\(outcome.sent) mails sent"
            }
            return "\(outcome.sent) sent · \(outcome.failed.count) failed"
        case .due(let batch):
            return "Scheduled mail is ready"
                + (batch.pending > 1 ? " · \(batch.pending)" : "")
        case .paused(let batches):
            let waiting = batches.reduce(0) { $0 + $1.pending }
            return "Queue paused · \(waiting) to go"
        case .scheduled(let batch):
            return "Scheduled · " + (batch.scheduledFor?.formatted(date: .omitted, time: .shortened) ?? "")
        case .idle:
            return ""
        }
    }

    private var subtitle: String {
        switch mode {
        case .sending:
            if queue.isStopping { return "Finishing the mail already on its way" }
            if let cooldown = queue.cooldown {
                return "Gmail asked to slow down · trying again at "
                    + cooldown.until.formatted(date: .omitted, time: .standard)
            }
            return "\(queue.completed) of \(queue.total) · \(queue.running?.liveCompany ?? "")"
        case .result(let outcome):
            if let reason = outcome.stoppedBecause { return reason }
            if outcome.isPaused { return "Tap to open it in Activity and resume" }
            guard !outcome.failed.isEmpty else {
                return (queue.batch(outcome.batchID)?.companiesLabel).map { "\($0) · tap to open it in Activity" } ?? "Tap to open it in Activity"
            }
            // Why they failed, which is what decides what to do next — a list
            // of names ("Couldn't reach Priya, Rahul") read as a network fault
            // whatever the cause was.
            if let why = queue.batch(outcome.batchID)?.failureSummary { return why }
            return "Couldn't send to \(outcome.failed.prefix(2).joined(separator: ", "))"
                + (outcome.failed.count > 2 ? " and \(outcome.failed.count - 2) more" : "")
        case .due(let batch):
            return "\(batch.companiesLabel) · tap Review to see it and send"
        case .paused(let batches):
            if batches.count == 1, let reason = batches[0].pauseReason { return reason }
            return batches.count == 1 ? "\(batches[0].liveCompany) · tap to open it in Activity" : "\(batches.count) batches · tap to open it in Activity"
        case .scheduled(let batch):
            let day = batch.scheduledFor.map { Calendar.current.isDateInToday($0) ? "today" : $0.formatted(.dateTime.weekday(.wide)) } ?? ""
            return "\(batch.pending) mail\(batch.pending == 1 ? "" : "s") · \(batch.companiesLabel) · \(day)"
        case .idle:
            return ""
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch mode {
        case .sending:
            Button {
                // Stopping a run mid-flight is the destructive control here.
                Haptics.thud()
                if let id = queue.runningBatchID { queue.pause(id) }
            } label: {
                Text("Pause")
                    .font(.caption.weight(.semibold))
            }
            // Bordered, not glass: the shelf is already glass, and glass on glass
            // is two panes rendering (and trailing each other) at once.
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(queue.isStopping)
        case .result, .scheduled:
            // Says what a tap does: opens the queue.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.inkMuted)
        case .due(let batch):
            Button {
                Haptics.press()
                queue.unsnooze(batch.id)
            } label: {
                Text("Review")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        case .paused(let batches):
            Button {
                Haptics.press()
                if let first = batches.first { queue.resume(first.id) }
            } label: {
                Text("Resume")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        case .idle:
            EmptyView()
        }
    }
}
