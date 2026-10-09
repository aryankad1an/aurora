import ActivityKit
import SwiftUI

/// The mail queue's Live Activity (`SendActivityAttributes`, drawn by the
/// AuroraLive extension). There is only ever one: started when a run begins
/// (or a scheduled batch comes within a few hours of its time), kept through
/// pauses and retries — a run that carries on updates it rather than starting
/// another — and ended, showing how it finished, when the queue has nothing
/// left to do.
///
/// `MailQueue` calls `sync(with:)` whenever something on it changes (its
/// `onChange`); this works out what the activity should say and only talks to
/// the system when that changed, so calling it often costs nothing.
@MainActor
final class SendLiveActivity {
    static let shared = SendLiveActivity()

    private var activity: Activity<SendActivityAttributes>?
    private var shown: ActivityContent<SendActivityAttributes.ContentState>?
    /// Whether this launch has looked for an activity a previous one left up.
    private var adopted = false

    /// How long a finished run stays on the Lock Screen.
    private static let lingerDone: TimeInterval = 15 * 60
    /// A scheduled batch's activity starts this long before its time at most:
    /// iOS ends a Live Activity after eight hours.
    private static let scheduledLead: TimeInterval = 7 * 60 * 60

    func sync(with queue: MailQueue) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        adoptLeftover()
        if let content = Self.content(for: queue) {
            show(content)
        } else if let activity {
            // Nothing left to show: say how the run ended, then let it go.
            let final = Self.finalState(queue: queue) ?? shown?.state
            self.activity = nil
            shown = nil
            guard let final, final.phase == .done else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                return
            }
            Task {
                await activity.end(ActivityContent(state: final, staleDate: nil),
                                   dismissalPolicy: .after(.now.addingTimeInterval(Self.lingerDone)))
            }
        }
    }

    /// Take over the activity a previous launch left up (the app was closed
    /// mid-run, and the run carries on), so carrying on doesn't put a second
    /// one beside it.
    private func adoptLeftover() {
        guard !adopted else { return }
        adopted = true
        let live = Activity<SendActivityAttributes>.activities.filter { $0.activityState == .active }
        activity = live.first
        for extra in live.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func show(_ content: ActivityContent<SendActivityAttributes.ContentState>) {
        if let activity, activity.activityState == .active {
            guard content.state != shown?.state || content.staleDate != shown?.staleDate else { return }
            shown = content
            Task { await activity.update(content) }
            return
        }
        let palette = ThemeStore.shared.current.palette
        let attributes = SendActivityAttributes(accent: Self.rgb(palette.accent),
                                                reply: Self.rgb(palette.reply),
                                                attention: Self.rgb(palette.attention),
                                                mark: ThemeStore.shared.current.mark)
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            shown = content
        } catch {
            // Turned off for the app, or too many running: the shelf in the app
            // still says everything this would.
            activity = nil
        }
    }

    /// What the activity should say now, or nil when there's nothing to show.
    /// In order: the batch sending; the batch stopped mid-run (paused, or
    /// waiting to retry); a scheduled batch that's due; one coming up.
    private static func content(for queue: MailQueue) -> ActivityContent<SendActivityAttributes.ContentState>? {
        if let running = queue.running {
            return ActivityContent(state: state(running: running, queue: queue), staleDate: nil)
        }
        if let held = heldBatch(in: queue) {
            return ActivityContent(state: state(held: held), staleDate: nil)
        }
        if let ready = queue.readyBatch {
            return ActivityContent(state: state(scheduled: ready), staleDate: nil)
        }
        if let next = queue.nextScheduled, let at = next.scheduledFor,
           at.timeIntervalSinceNow < scheduledLead {
            // Stale at its time: the extension then shows it ready to send,
            // without the app having to run to say so.
            return ActivityContent(state: state(scheduled: next), staleDate: at)
        }
        return nil
    }

    /// A batch stopped partway with mail left that the activity keeps showing:
    /// one carrying on by itself, or the one the activity was already about.
    private static func heldBatch(in queue: MailQueue) -> MailBatch? {
        let stopped = queue.batches.filter { $0.isPaused && $0.hasWork && $0.startedAt != nil }
        if let id = shared.shown?.state.batchID, let same = stopped.first(where: { $0.id.uuidString == id }) {
            return same
        }
        return stopped.first { $0.resumeAt != nil }
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
                     resumesAt: cooldown?.until, note: cooldown.map { _ in "Gmail asked to slow down" },
                     batchID: batch.id.uuidString)
    }

    private static func state(held batch: MailBatch) -> SendActivityAttributes.ContentState {
        let next = batch.mails.first(where: \.status.isWaiting)
        return .init(phase: batch.resumeAt != nil ? .waiting : .paused, title: batch.title,
                     sent: batch.sent, failed: batch.failed, total: batch.mails.count,
                     recipient: next?.displayName, recipientEmail: next?.recipient, company: next?.company,
                     resumesAt: batch.resumeAt, note: batch.stopNote, batchID: batch.id.uuidString)
    }

    private static func state(scheduled batch: MailBatch) -> SendActivityAttributes.ContentState {
        .init(phase: .scheduled, title: batch.title, sent: batch.sent, failed: batch.failed,
              total: batch.mails.count, recipient: nil, recipientEmail: nil,
              company: batch.companies.count == 1 ? batch.companies.first : "\(batch.companies.count) companies",
              resumesAt: nil, note: nil, batchID: batch.id.uuidString, startsAt: batch.scheduledFor)
    }

    /// How the run ended, from the last batch it sent.
    private static func finalState(queue: MailQueue) -> SendActivityAttributes.ContentState? {
        guard let outcome = queue.outcome, let batch = queue.batch(outcome.batchID) else { return nil }
        return .init(phase: outcome.isPaused ? .paused : .done, title: batch.title,
                     sent: batch.sent, failed: batch.failed, total: batch.mails.count,
                     recipient: nil, recipientEmail: nil, company: nil,
                     resumesAt: batch.resumeAt, note: batch.stopNote, batchID: batch.id.uuidString)
    }

    private static func rgb(_ color: Color) -> SendActivityAttributes.RGB {
        let resolved = color.resolve(in: EnvironmentValues())
        return .init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }
}
