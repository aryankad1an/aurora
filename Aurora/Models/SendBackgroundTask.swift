import BackgroundTasks
import Foundation
import UIKit

/// Keeps the send queue running after the app leaves the screen or the phone
/// locks, through a `BGContinuedProcessingTask`: work a person started in the
/// app that iOS lets finish in the background, with its own progress UI.
///
/// It only buys time. The queue sends exactly as it does on screen — one run at
/// a time, every mail saved as `sending` before it's handed to Gmail, and any
/// mail whose answer never came looked for in Sent before it can go again — so
/// nothing about being in the background can mail someone twice. When iOS ends
/// the time early (or Stop is tapped in its UI; the two can't be told apart),
/// the running batch is paused with a note saying so, and Resume carries on
/// from where it stopped, checking anything cut off in Sent first.
///
/// iOS only grants one while the app is on screen, so one is asked for when a
/// run is under way with the app in front — the moment Send or Resume is
/// tapped, or the app is opened again mid-run. One task covers the queue until
/// it has nothing left to do soon, batch after batch, rather than one per batch:
/// a new one can't be started from the background.
///
/// The system expires a task whose progress stops moving for about half a
/// minute, so progress ticks on its own between mails — through the gap, a
/// check of Sent mail, a bounce check, or a wait on Gmail — without ever
/// reaching the next mail's share.
///
/// iOS shows the task in a Live Activity of its own, which the app can't hide
/// or restyle — only title. While it's up, `SendLiveActivity` keeps out of the
/// way, so the run is one card on the Lock Screen; the titles here say what
/// that one would have, the bounce check and how the run ended included.
@MainActor
final class SendBackgroundTask {
    static let shared = SendBackgroundTask()

    /// `BGTaskSchedulerPermittedIdentifiers` in Info.plist holds this with
    /// `.*`; each task adds its own suffix.
    private static let prefix = "com.realaryan.JTracker.send"
    /// Each mail's share of the progress, in units: room for the ticks between.
    private static let unitsPerMail: Int64 = 1000
    /// How often progress ticks on its own.
    private static let heartbeat: Duration = .seconds(3)
    /// A batch carrying on by itself within this long (a retry after a dropped
    /// connection) keeps the task — the queue isn't done. Longer than this (a
    /// daily sending limit) and it's let go.
    private static let retryHorizon: TimeInterval = 10 * 60

    private weak var queue: MailQueue?
    private var task: BGContinuedProcessingTask?
    /// Asked for, and not yet started or refused.
    private var isRequesting = false
    /// When iOS last refused one: not asked again for a minute, rather than on
    /// every change the queue makes.
    private var refusedAt: Date?
    private var ticker: Task<Void, Never>?
    private var shownTitle: (title: String, subtitle: String)?
    /// Mails finished since the task began, and the queue-wide count they're
    /// worked out from. Counted, not read off the batches: a finished batch
    /// can be removed, and progress must never go back.
    private var finished = 0
    private var lastFinished = 0

    /// Whether the system's card is up for the queue, or about to be.
    var isHolding: Bool { task != nil || isRequesting }

    /// Bring the task in line with the queue: ask for one when a run is under
    /// way on screen, report how far it's got, and hand it back once the queue
    /// has nothing left to do soon.
    func sync(with queue: MailQueue) {
        self.queue = queue
        guard needsTime(queue) else {
            finish(success: true)
            return
        }
        if let task {
            report(queue, to: task)
        } else if queue.running != nil, !isRequesting,
                  UIApplication.shared.applicationState == .active,
                  refusedAt.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
            request(for: queue)
        }
    }

    /// Whether the queue has work that background time would let go on: a run,
    /// or a batch about to carry on by itself.
    private func needsTime(_ queue: MailQueue) -> Bool {
        if queue.running != nil { return true }
        let soon = Date.now.addingTimeInterval(Self.retryHorizon)
        return queue.batches.contains { $0.isPaused && $0.hasWork && ($0.resumeAt.map { $0 <= soon } ?? false) }
    }

    // MARK: - Lifecycle

    private func request(for queue: MailQueue) {
        // Handlers can't be unregistered, and one registered for the wildcard
        // isn't matched to the ids submitted under it: each task registers its
        // own id, right before it's submitted.
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
        let pending = queue.batches.reduce(0) { $0 + $1.pending }
        let (title, subtitle) = titles(for: queue, done: 0, total: pending)
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Now or not at all: queued, it could start long after the run it was for.
        request.strategy = .fail
        isRequesting = true
        Task {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                // Refused (too many running, the system under load): the queue
                // still has the few seconds `beginBackgroundTask` gives, and goes
                // on when the app is opened again, as it always has.
                isRequesting = false
                refusedAt = .now
                handBack()
            }
        }
    }

    private func started(_ task: BGContinuedProcessingTask) {
        isRequesting = false
        guard let queue, needsTime(queue) else {
            task.setTaskCompleted(success: true)
            handBack()
            return
        }
        self.task = task
        shownTitle = nil
        finished = 0
        lastFinished = Self.allFinished(queue)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
        report(queue, to: task)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                self?.tick()
            }
        }
    }

    /// iOS ended the time, or Stop was tapped. Off screen, the run is paused:
    /// it would be frozen mid-way otherwise, and Resume says plainly what
    /// happens next. On screen the app keeps running, so the run goes on.
    private func expired() {
        guard let task else { return }
        if UIApplication.shared.applicationState != .active, let queue, let running = queue.runningBatchID {
            queue.pause(running, because: "Stopped in the background. Resume to carry on — anything cut off is checked in Sent mail before it's sent again.")
        }
        ticker?.cancel()
        ticker = nil
        self.task = nil
        task.setTaskCompleted(success: false)
        handBack()
    }

    private func finish(success: Bool) {
        ticker?.cancel()
        ticker = nil
        guard let task else { return }
        self.task = nil
        if success {
            // The card's last word: how the run went, bounces and all.
            if let queue, let closing = closingTitles(for: queue) {
                task.updateTitle(closing.title, subtitle: closing.subtitle)
            }
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        task.setTaskCompleted(success: success)
        handBack()
    }

    /// The system's card is gone: the app's own Live Activity carries on with
    /// anything still to show.
    private func handBack() {
        if let queue { SendLiveActivity.shared.sync(with: queue) }
    }

    // MARK: - Progress

    private static func allFinished(_ queue: MailQueue) -> Int {
        queue.batches.reduce(0) { $0 + $1.sent + $1.failed }
    }

    /// Mails finished since the task began, and how many that makes with
    /// those still to go.
    private func counts(_ queue: MailQueue) -> (done: Int, total: Int) {
        let now = Self.allFinished(queue)
        if now > lastFinished { finished += now - lastFinished }
        lastFinished = now
        return (finished, finished + queue.batches.reduce(0) { $0 + $1.pending })
    }

    private func report(_ queue: MailQueue, to task: BGContinuedProcessingTask) {
        let (done, total) = counts(queue)
        let progress = task.progress
        progress.totalUnitCount = max(progress.totalUnitCount, Int64(max(total, 1)) * Self.unitsPerMail)
        let floor = Int64(done) * Self.unitsPerMail
        if floor > progress.completedUnitCount { progress.completedUnitCount = min(floor, progress.totalUnitCount - 1) }
        let titles = titles(for: queue, done: done, total: total)
        if shownTitle?.title != titles.title || shownTitle?.subtitle != titles.subtitle {
            shownTitle = titles
            task.updateTitle(titles.title, subtitle: titles.subtitle)
        }
    }

    /// Progress moving on its own between mails, up to just short of the next
    /// mail's share — so it shows time passing, never a mail that hasn't gone.
    private func tick() {
        guard let task, let queue else { return }
        let progress = task.progress
        let (done, _) = counts(queue)
        let ceiling = (Int64(done) + 1) * Self.unitsPerMail - 1
        if progress.completedUnitCount < min(ceiling, progress.totalUnitCount - 1) {
            progress.completedUnitCount += 1
        }
    }

    private func titles(for queue: MailQueue, done: Int, total: Int) -> (title: String, subtitle: String) {
        let title: String
        switch queue.step {
        case .awaitingBounces, .checkingBounces:
            title = "Checking for bounces · \(done) of \(total) sent"
        default:
            title = "\(total == 1 ? "Sending mail" : "Sending mails") · \(done) of \(total)"
        }
        if let cooldown = queue.cooldown {
            return (title, "Gmail asked to slow down · trying again at "
                    + cooldown.until.formatted(date: .omitted, time: .shortened))
        }
        if let step = queue.step { return (title, step.summary) }
        if queue.running == nil,
           let next = queue.batches.compactMap({ $0.isPaused && $0.hasWork ? $0.resumeAt : nil }).min() {
            return (title, "Trying again at " + next.formatted(date: .omitted, time: .shortened))
        }
        return (title, queue.running?.liveCompany ?? "")
    }

    /// "All 4 mails sent" over "No bounces", once the run has finished.
    private func closingTitles(for queue: MailQueue) -> (title: String, subtitle: String)? {
        guard let outcome = queue.outcome, !outcome.isPaused else { return nil }
        let (done, _) = counts(queue)
        let failed = outcome.failed.count
        let title = failed > 0 ? "\(max(done - failed, 0)) sent · \(failed) failed"
            : done == 1 ? "Mail sent" : "All \(done) mails sent"
        let subtitle = switch outcome.bounced {
        case nil: queue.batch(outcome.batchID)?.companiesLabel ?? ""
        case 0?: "No bounces"
        case let count?: count == 1 ? "1 bounced" : "\(count) bounced"
        }
        return (title, subtitle)
    }
}
