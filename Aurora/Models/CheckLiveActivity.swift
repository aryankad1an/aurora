import ActivityKit
import SwiftUI

/// A reply check's Live Activity (`CheckActivityAttributes`, drawn by the
/// AuroraLive extension), for a check long enough to leave the app during:
/// started once one has run `CheckBackgroundTask.threshold` on screen, and
/// ended when it does, saying what it found: for ten minutes when it found
/// anything, a minute when not.
///
/// It steps aside for the system's card while `CheckBackgroundTask` holds the
/// check, and for the send queue's Live Activity and background task, which
/// already say when they're checking for bounces: there's only ever one card
/// for what the app is doing. A Live Activity can only be started with the
/// app open, so checks the phone runs by itself (`BackgroundCheck`) tell what
/// they find in notifications instead.
@MainActor
final class CheckLiveActivity {
    static let shared = CheckLiveActivity()

    private var activity: Activity<CheckActivityAttributes>?
    private var shown: CheckActivityAttributes.ContentState?
    /// When the check under way began, as far as this knows.
    private var checkStartedAt: Date?
    private var lastUpdate = Date.distantPast
    /// An update held back by `minimumGap`, sent when the gap is up.
    private var held: Task<Void, Never>?
    private var adopted = false
    /// When the card up goes stale, as last sent.
    private var staleAt: Date?
    /// The card was swiped away during this check: not put back up for it.
    private var dismissedThisCheck = false
    private weak var replySync: ReplySync?
    /// Tells the card it's still current while the check runs.
    private var keepingAlive: Task<Void, Never>?

    /// How long a check that found something stays on the Lock Screen, and
    /// one that found nothing.
    private static let lingerFound: TimeInterval = 10 * 60
    private static let lingerNothing: TimeInterval = 60
    /// Updates go no more often than this: a check moves on every few reads.
    private static let minimumGap: TimeInterval = 1
    /// The card goes stale this long after the app last said the check is
    /// going: suspended mid-check, it can't update it, and a stale card says
    /// to open Aurora rather than "Checking" for hours.
    private static let staleAfter: TimeInterval = 3 * 60
    /// How often it's told it's still current with nothing new to say: a
    /// read can wait a minute or more on Gmail's rate limit.
    private static let heartbeat: TimeInterval = 60

    func sync(with sync: ReplySync) {
        replySync = sync
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        adoptLeftover()
        guard sync.isSyncing else {
            checkStartedAt = nil
            dismissedThisCheck = false
            end(with: Self.finalState(sync))
            return
        }
        let startedAt = checkStartedAt ?? .now
        checkStartedAt = startedAt
        if CheckBackgroundTask.shared.isHolding || SendBackgroundTask.shared.isHolding
            || SendLiveActivity.shared.isShowing {
            end(with: nil)
            return
        }
        let state = Self.state(sync)
        if let activity, activity.activityState.isUp {
            update(activity, to: state, from: sync)
            return
        }
        if let activity, activity.activityState == .dismissed {
            // Swiped away: it stays away until the next check.
            dismissedThisCheck = true
            self.activity = nil
            shown = nil
        }
        if !dismissedThisCheck,
           Date.now.timeIntervalSince(startedAt) >= Double(CheckBackgroundTask.threshold.components.seconds),
           UIApplication.shared.applicationState == .active {
            start(state)
        }
    }

    /// Take over an activity a previous launch left up, so it isn't stranded.
    private func adoptLeftover() {
        guard !adopted else { return }
        adopted = true
        for leftover in Activity<CheckActivityAttributes>.activities where leftover.activityState.isUp {
            // A check doesn't outlive its launch: whatever it said is over.
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func start(_ state: CheckActivityAttributes.ContentState) {
        let attributes = CheckActivityAttributes(accent: SendLiveActivity.rgb(Palette.clay),
                                                 reply: SendLiveActivity.rgb(Palette.olive),
                                                 attention: SendLiveActivity.rgb(Palette.kraft))
        do {
            let staleAt = Self.staleDate()
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: staleAt), pushType: nil)
            shown = state
            self.staleAt = staleAt
            lastUpdate = .now
            keepAlive()
        } catch {
            // Turned off for the app, or too many running: Activity still says it.
            activity = nil
        }
    }

    private func update(_ activity: Activity<CheckActivityAttributes>, to state: CheckActivityAttributes.ContentState,
                        from sync: ReplySync) {
        // Nothing new: sent again only to put off going stale, once a heartbeat on.
        let renew = staleAt.map { Self.staleDate().timeIntervalSince($0) >= Self.heartbeat } ?? true
        guard state != shown || renew else { return }
        let wait = Self.minimumGap - Date.now.timeIntervalSince(lastUpdate)
        guard wait <= 0 else {
            // The newest state goes out when the gap is up.
            guard held == nil else { return }
            held = Task { [weak self, weak sync] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                held = nil
                if let sync, sync.isSyncing { self.sync(with: sync) }
            }
            return
        }
        shown = state
        lastUpdate = .now
        let staleAt = Self.staleDate()
        self.staleAt = staleAt
        Task { await activity.update(ActivityContent(state: state, staleDate: staleAt)) }
    }

    private static func staleDate() -> Date { .now.addingTimeInterval(staleAfter) }

    /// Renew the stale date while the app is checking. Stops by itself once
    /// there's no activity; while the app is suspended it doesn't run, which
    /// is the point.
    private func keepAlive() {
        guard keepingAlive == nil else { return }
        keepingAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeat))
                guard let self, self.activity != nil, let sync = self.replySync else { break }
                self.sync(with: sync)
            }
            self?.keepingAlive = nil
        }
    }

    /// End the activity: on what the check found, left up a while if it
    /// found anything, or straight away.
    private func end(with final: CheckActivityAttributes.ContentState?) {
        held?.cancel()
        held = nil
        guard let activity else { return }
        self.activity = nil
        shown = nil
        staleAt = nil
        guard let final else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let found = final.replies > 0 || final.bounced > 0
        let linger = found ? Self.lingerFound : Self.lingerNothing
        let policy: ActivityUIDismissalPolicy = .after(.now.addingTimeInterval(linger))
        Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: policy) }
    }

    // MARK: - State

    private static func state(_ sync: ReplySync) -> CheckActivityAttributes.ContentState {
        let progress = sync.progress
        let detail = progress.total > 0
            ? "\(min(progress.done, progress.total)) of \(progress.total) \(progress.unit)" : nil
        return .init(phase: .checking, label: progress.label.isEmpty ? "Getting ready" : progress.label,
                     step: progress.step, steps: progress.steps,
                     // Rounded, so a read finishing doesn't count as a change.
                     overall: (progress.overall * 50).rounded() / 50,
                     detail: detail, replies: 0, bounced: 0, note: nil)
    }

    private static func finalState(_ sync: ReplySync) -> CheckActivityAttributes.ContentState? {
        guard let run = sync.lastRun else { return nil }
        let replies = run.outcome.newReplies.count, bounced = run.outcome.newBounces.count
        let closing = CheckBackgroundTask.closingTitles(for: sync)
        // Who: "Dev Mehta at Northwind Labs and 2 more".
        let found = run.outcome.newReplies + run.outcome.newBounces
        let who = found.first.map { first in
            (first.company.map { "\(first.name) at \($0)" } ?? first.name)
                + (found.count > 1 ? " and \(found.count - 1) more" : "")
        }
        return .init(phase: run.completed ? .done : .stopped, label: closing.title,
                     step: 0, steps: 0, overall: 1, detail: who,
                     replies: replies, bounced: bounced, note: run.completed ? nil : closing.subtitle)
    }
}
