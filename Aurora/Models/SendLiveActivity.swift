import ActivityKit
import SwiftUI

/// The mail queue's Live Activity (`SendActivityAttributes`, drawn by the
/// AuroraLive extension): started when a run begins, kept up to date as each
/// mail goes, and ended — showing how it finished — when the queue has nothing
/// left to send.
///
/// `MailQueue` calls `sync(with:)` whenever something on it changes; this works
/// out what the activity should say and only talks to the system when that
/// changed, so calling it often costs nothing.
@MainActor
final class SendLiveActivity {
    static let shared = SendLiveActivity()

    private var activity: Activity<SendActivityAttributes>?
    private var shown: SendActivityAttributes.ContentState?

    /// How long a finished run stays on the Lock Screen.
    private static let lingerDone: TimeInterval = 15 * 60

    /// End anything a previous launch left up: the app was closed mid-run, and
    /// the batch it was sending comes back paused, on screen in the app.
    func reset() {
        activity = nil
        shown = nil
        for stale in Activity<SendActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func sync(with queue: MailQueue) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let running = queue.running {
            let state = Self.state(running: running, queue: queue)
            if let activity, activity.activityState == .active {
                guard state != shown else { return }
                shown = state
                Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                start(state)
            }
        } else if let activity {
            // The run is over: say how, then let it go.
            let state = Self.finalState(queue: queue) ?? shown
            self.activity = nil
            shown = nil
            guard let state else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                return
            }
            let policy: ActivityUIDismissalPolicy = state.phase == .done
                ? .after(.now.addingTimeInterval(Self.lingerDone)) : .default
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
        }
    }

    private func start(_ state: SendActivityAttributes.ContentState) {
        let palette = ThemeStore.shared.current.palette
        let attributes = SendActivityAttributes(accent: Self.rgb(palette.accent),
                                                reply: Self.rgb(palette.reply),
                                                attention: Self.rgb(palette.attention),
                                                mark: ThemeStore.shared.current.mark)
        do {
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
            shown = state
        } catch {
            // Turned off for the app, or too many running: the shelf in the app
            // still says everything this would.
            activity = nil
        }
    }

    private static func state(running batch: MailBatch, queue: MailQueue) -> SendActivityAttributes.ContentState {
        let cooldown = queue.cooldown?.batchID == batch.id ? queue.cooldown : nil
        let phase: SendActivityAttributes.ContentState.Phase =
            cooldown != nil ? .waiting : queue.isStopping ? .pausing : .sending
        // The mail on its way — or, while waiting, the one that goes next.
        let current = batch.mails.first { if case .sending = $0.status { true } else { false } }
            ?? batch.mails.first(where: \.status.isWaiting)
        return .init(phase: phase, title: batch.title, sent: batch.sent, failed: batch.failed,
                     total: batch.mails.count, recipient: current?.displayName,
                     recipientEmail: current?.recipient, company: current?.company,
                     resumesAt: cooldown?.until, note: cooldown?.reason)
    }

    /// How the run ended, from the last batch it sent.
    private static func finalState(queue: MailQueue) -> SendActivityAttributes.ContentState? {
        guard let outcome = queue.outcome, let batch = queue.batch(outcome.batchID) else { return nil }
        return .init(phase: outcome.isPaused ? .paused : .done, title: batch.title,
                     sent: batch.sent, failed: batch.failed, total: batch.mails.count,
                     recipient: nil, recipientEmail: nil, company: nil,
                     resumesAt: batch.resumeAt, note: outcome.stoppedBecause)
    }

    private static func rgb(_ color: Color) -> SendActivityAttributes.RGB {
        let resolved = color.resolve(in: EnvironmentValues())
        return .init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }
}
