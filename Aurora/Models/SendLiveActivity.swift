import ActivityKit
import SwiftUI

/// The mail queue's Live Activity (`SendActivityAttributes`, drawn by the
/// AuroraLive extension). There is only ever one: started when a run begins
/// (or a scheduled batch comes within a few hours of its time), kept through
/// pauses and retries — a run that carries on updates it rather than starting
/// another — and ended, showing how it finished, when the queue has nothing
/// left to do.
///
/// While `SendBackgroundTask` holds the queue, iOS already shows the run in a
/// Live Activity of its own, which can't be hidden; this one steps aside then,
/// so the run is only ever one card. It covers what that one doesn't: a run
/// iOS refused background time for, a batch stopped or waiting to retry, and a
/// scheduled batch coming up.
///
/// `MailQueue` calls `sync(with:)` whenever something on it changes (its
/// `onChange`); this works out what the activity should say and only talks to
/// the system when that changed, so calling it often costs nothing.
@MainActor
final class SendLiveActivity {
    static let shared = SendLiveActivity()

    private var activity: Activity<SendActivityAttributes>?
    private var shown: ActivityContent<SendActivityAttributes.ContentState>?
    /// The batch last shown, here or in the background task's card: a batch
    /// that stops is kept showing, paused, whichever card it was in.
    private var batchID: String?
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
        if SendBackgroundTask.shared.isHolding {
            if let running = queue.running { batchID = running.id.uuidString }
            if let activity {
                self.activity = nil
                shown = nil
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
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
            batchID = content.state.batchID
            Task { await activity.update(content) }
            return
        }
        let attributes = SendActivityAttributes(accent: Self.rgb(Palette.clay),
                                                reply: Self.rgb(Palette.olive),
                                                attention: Self.rgb(Palette.kraft))
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            shown = content
            batchID = content.state.batchID
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
        if let id = shared.batchID, let same = stopped.first(where: { $0.id.uuidString == id }) {
            return same
        }
        return stopped.first { $0.resumeAt != nil }
    }

    private static func state(running batch: MailBatch, queue: MailQueue) -> SendActivityAttributes.ContentState {
        let cooldown = queue.cooldown?.batchID == batch.id ? queue.cooldown : nil
        let checking = switch queue.step {
        case .awaitingBounces, .checkingBounces: true
        default: false
        }
        let phase: SendActivityAttributes.ContentState.Phase =
            cooldown != nil ? .waiting : queue.isStopping ? .pausing : checking ? .checking : .sending
        // The mail on its way — or, while waiting, the one that goes next.
        // None once they've all gone.
        let current = checking ? nil : batch.current
        // A step worth saying instead of "Sending mail 4 of 11". Not the
        // second's gap between mails, which would only make it flicker.
        let step: String? = switch queue.step {
        case .checkingSent, .awaitingBounces, .checkingBounces: queue.step?.summary
        default: nil
        }
        return .init(phase: phase, title: batch.liveCompany, sent: batch.sent, failed: batch.failed,
                     total: batch.mails.count, recipient: current?.displayName,
                     recipientEmail: current?.recipient, company: current?.company,
                     resumesAt: cooldown?.until, note: cooldown.map { _ in "Gmail asked to slow down" } ?? step,
                     batchID: batch.id.uuidString)
    }

    private static func state(held batch: MailBatch) -> SendActivityAttributes.ContentState {
        let next = batch.mails.first(where: \.status.isWaiting)
        return .init(phase: batch.resumeAt != nil ? .waiting : .paused, title: batch.liveCompany,
                     sent: batch.sent, failed: batch.failed, total: batch.mails.count,
                     recipient: next?.displayName, recipientEmail: next?.recipient, company: next?.company,
                     resumesAt: batch.resumeAt, note: batch.stopNote, batchID: batch.id.uuidString)
    }

    private static func state(scheduled batch: MailBatch) -> SendActivityAttributes.ContentState {
        .init(phase: .scheduled, title: batch.companiesLabel, sent: batch.sent, failed: batch.failed,
              total: batch.mails.count, recipient: nil, recipientEmail: nil, company: nil,
              resumesAt: nil, note: nil, batchID: batch.id.uuidString, startsAt: batch.scheduledFor)
    }

    /// How the run ended, from the last batch it sent.
    private static func finalState(queue: MailQueue) -> SendActivityAttributes.ContentState? {
        guard let outcome = queue.outcome, let batch = queue.batch(outcome.batchID) else { return nil }
        return .init(phase: outcome.isPaused ? .paused : .done, title: batch.companiesLabel,
                     sent: batch.sent, failed: batch.failed, total: batch.mails.count,
                     recipient: nil, recipientEmail: nil, company: nil,
                     resumesAt: batch.resumeAt, note: batch.stopNote, batchID: batch.id.uuidString,
                     bounced: outcome.bounced)
    }

    static func rgb(_ color: Color) -> SendActivityAttributes.RGB {
        let resolved = color.resolve(in: EnvironmentValues())
        return .init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }
}
