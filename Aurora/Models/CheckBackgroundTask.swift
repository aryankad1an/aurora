import BackgroundTasks
import Foundation
import UIKit

/// Keeps a reply check going after the app leaves the screen, through a
/// `BGContinuedProcessingTask` — the send queue's `SendBackgroundTask`, for
/// checks. A full check of a busy mailbox reads for a minute or more, and
/// without this, leaving the app froze it partway, to start over next time.
///
/// iOS only grants one while the app is on screen, so it's asked for once a
/// check has been running `threshold` with the app in front: the quick checks
/// most launches run finish before then, and never put a card up. While the
/// send queue holds its own task the app already has the time, and none is
/// asked for.
///
/// When iOS ends the time (or Stop is tapped on its card) with the app off
/// screen, the check stops at its next read and keeps what it found; the next
/// check reads from where this one began. Progress ticks on its own between
/// reads, since iOS expires a task whose progress stops moving.
@MainActor
final class CheckBackgroundTask {
    static let shared = CheckBackgroundTask()

    /// `BGTaskSchedulerPermittedIdentifiers` in Info.plist holds this with
    /// `.*`; each task adds its own suffix.
    private static let prefix = "com.realaryan.JTracker.check.run"
    /// Each step's share of the progress, in units: room for the ticks between.
    private static let unitsPerStep: Int64 = 1000
    private static let heartbeat: Duration = .seconds(3)
    /// How long a check runs on screen before background time is asked for.
    static let threshold: Duration = .seconds(3)

    private weak var replySync: ReplySync?
    private var task: BGContinuedProcessingTask?
    private var isRequesting = false
    /// Waiting out `threshold` for the check under way.
    private var waiting: Task<Void, Never>?
    /// Asked for during this check already: refused once, not asked again.
    private var askedThisCheck = false
    private var wasSyncing = false
    private var ticker: Task<Void, Never>?
    private var shownTitle: (title: String, subtitle: String)?

    /// Whether the system's card is up for the check, or about to be.
    var isHolding: Bool { task != nil || isRequesting }

    func sync(with sync: ReplySync) {
        replySync = sync
        defer { wasSyncing = sync.isSyncing }
        guard sync.isSyncing else {
            waiting?.cancel()
            waiting = nil
            finish()
            return
        }
        if !wasSyncing { askedThisCheck = false }
        if let task {
            report(sync, to: task)
        } else if waiting == nil, !askedThisCheck, !isRequesting {
            waiting = Task { [weak self] in
                try? await Task.sleep(for: Self.threshold)
                guard !Task.isCancelled, let self else { return }
                waiting = nil
                requestIfNeeded()
                // Past the threshold: the check's own Live Activity may go up.
                if let replySync { CheckLiveActivity.shared.sync(with: replySync) }
            }
        }
    }

    private func requestIfNeeded() {
        guard let replySync, replySync.isSyncing, task == nil, !isRequesting, !askedThisCheck,
              !SendBackgroundTask.shared.isHolding,
              UIApplication.shared.applicationState == .active else { return }
        askedThisCheck = true
        // Each task registers its own id right before it's submitted (see
        // `SendBackgroundTask.request`).
        let identifier = "\(Self.prefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.started(task)
            }
        }
        guard registered else { return }
        let (title, subtitle) = Self.titles(for: replySync)
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        isRequesting = true
        Task {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                // Refused: the check goes on while the app is open, as before.
                isRequesting = false
                handBack()
            }
        }
    }

    private func started(_ task: BGContinuedProcessingTask) {
        isRequesting = false
        guard let replySync, replySync.isSyncing else {
            task.setTaskCompleted(success: true)
            handBack()
            return
        }
        self.task = task
        shownTitle = nil
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
        report(replySync, to: task)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                self?.tick()
            }
        }
    }

    /// iOS ended the time, or Stop was tapped. Off screen, the check stops
    /// rather than freezing partway; on screen it carries on.
    private func expired() {
        guard let task else { return }
        if UIApplication.shared.applicationState != .active {
            replySync?.stop("Stopped in the background. The next check carries on from here.")
        }
        ticker?.cancel()
        ticker = nil
        self.task = nil
        task.setTaskCompleted(success: false)
        handBack()
    }

    private func finish() {
        ticker?.cancel()
        ticker = nil
        guard let task else { return }
        self.task = nil
        // The card's last word: what the check found.
        if let replySync {
            let closing = Self.closingTitles(for: replySync)
            task.updateTitle(closing.title, subtitle: closing.subtitle)
        }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: true)
        handBack()
    }

    /// The system's card is gone: the check's own Live Activity carries on
    /// with anything still to show.
    private func handBack() {
        if let replySync { CheckLiveActivity.shared.sync(with: replySync) }
    }

    // MARK: - Progress

    private func report(_ sync: ReplySync, to task: BGContinuedProcessingTask) {
        let progress = task.progress
        let steps = Int64(max(sync.progress.steps, 1))
        progress.totalUnitCount = max(progress.totalUnitCount, steps * Self.unitsPerStep)
        let reached = Int64((sync.progress.overall * Double(steps * Self.unitsPerStep)).rounded(.down))
        if reached > progress.completedUnitCount {
            progress.completedUnitCount = min(reached, progress.totalUnitCount - 1)
        }
        let titles = Self.titles(for: sync)
        if shownTitle?.title != titles.title || shownTitle?.subtitle != titles.subtitle {
            shownTitle = titles
            task.updateTitle(titles.title, subtitle: titles.subtitle)
        }
    }

    /// Progress moving on its own, up to just short of the step's end — time
    /// passing, never a step that hasn't finished.
    private func tick() {
        guard let task, let replySync else { return }
        let progress = task.progress
        let step = Int64(max(replySync.progress.step, 1))
        let ceiling = step * Self.unitsPerStep - 1
        if progress.completedUnitCount < min(ceiling, progress.totalUnitCount - 1) {
            progress.completedUnitCount += 1
        }
    }

    private static func titles(for sync: ReplySync) -> (title: String, subtitle: String) {
        let progress = sync.progress
        var subtitle = progress.label
        if progress.total > 0 { subtitle += " · \(min(progress.done, progress.total)) of \(progress.total) \(progress.unit)" }
        if progress.steps > 0, progress.step > 0 {
            return ("Checking for replies · step \(progress.step) of \(progress.steps)", subtitle)
        }
        return ("Checking for replies", subtitle)
    }

    /// "2 replies · 1 bounced", or why it stopped.
    static func closingTitles(for sync: ReplySync) -> (title: String, subtitle: String) {
        guard let run = sync.lastRun, run.completed else {
            let found = sync.lastRun.map { $0.outcome.foundAnything ? " · " + found($0.outcome) : "" } ?? ""
            return ("Check stopped" + found, sync.errorMessage ?? "The next check carries on from here.")
        }
        return (found(run.outcome), "Your mail is checked")
    }

    /// "2 replies · 1 bounced", "1 reply", "Nothing new".
    static func found(_ outcome: ReplySync.Outcome) -> String {
        var parts: [String] = []
        let replies = outcome.newReplies.count, bounced = outcome.newBounces.count
        if replies > 0 { parts.append(replies == 1 ? "1 reply" : "\(replies) replies") }
        if bounced > 0 { parts.append("\(bounced) bounced") }
        return parts.isEmpty ? "No new replies or bounces" : parts.joined(separator: " · ")
    }
}
