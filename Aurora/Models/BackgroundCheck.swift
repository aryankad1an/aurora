import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// The stores a check the phone runs by itself shares with the app's screens:
/// one of each per launch. iOS can start the app in the background for a
/// check before — or without — any screen being made, and the screens made
/// later must read and write the same bounces, checkpoint and Gmail session.
@MainActor
enum AppServices {
    static let gmailAuth = GmailAuthStore()

    static let replySync: ReplySync = {
        let sync = ReplySync()
        sync.reader = { path, query in
            try await gmailAuth.gmailGET(path: path, query: query)
        }
        sync.onStateChange = { [weak sync] in
            guard let sync else { return }
            // The background time first: while it's held, its own card is
            // the check's one Live Activity.
            CheckBackgroundTask.shared.sync(with: sync)
            CheckLiveActivity.shared.sync(with: sync)
        }
        sync.onFinish = { outcome in
            CheckNotifier.notify(outcome)
        }
        return sync
    }()
}

/// Checks for replies and bounces while the app is closed, through a
/// `BGAppRefreshTask`. iOS decides when it runs — roughly as often as the app
/// is used, never more than every `interval`, and not at all with Background
/// App Refresh off or in Low Power Mode — and gives it about half a minute.
///
/// It's the check the app runs on opening, to a smaller budget
/// (`ReplySync.Budget.background`): only threads and notices, at most a few
/// dozen reads of each, paced like every read (`GmailReadPolicy`). What's over
/// the budget is read by the next check, never skipped. A check stopped by
/// Gmail's rate limit waits longer for the next. Anything found is told in a
/// notification (`CheckNotifier`), and the app's send history is reloaded on
/// coming back.
@MainActor
enum BackgroundCheck {
    /// Listed in Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
    nonisolated static let identifier = "com.realaryan.JTracker.check"

    /// The soonest iOS may run the next check.
    nonisolated private static let interval: TimeInterval = 30 * 60
    /// After Gmail asked to slow down.
    private static let rateLimitedInterval: TimeInterval = 60 * 60
    /// A check this recent, in the app or here, leaves nothing new to find.
    private static let freshFor: TimeInterval = 10 * 60

    /// Ask iOS for the next check. A request already waiting is replaced.
    static func schedule(after delay: TimeInterval = interval) {
        guard AppServices.gmailAuth.connectedEmail != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(delay)
        // Refused when Background App Refresh is off: the app checks on
        // opening, as it always has.
        Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
    }

    /// One check, started by iOS. Cancelled when its time runs out: the check
    /// stops at its next read and keeps what it found.
    static func run() async {
        let sync = AppServices.replySync
        defer { schedule(after: sync.wasRateLimited ? rateLimitedInterval : interval) }
        guard let email = AppServices.gmailAuth.connectedEmail else { return }

        // The app, opening in the background, may have begun its own check.
        while sync.isSyncing {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        if sync.account != email { sync.loadBounces(account: email) }
        if let last = sync.lastSyncedAt, Date.now.timeIntervalSince(last) < freshFor { return }

        // Contacts are sealed: their addresses can't be read without the keys.
        guard await VaultStore.openKeysQuietly(email: email),
              let inputs = try? await inputs(email: email) else { return }
        let outcome = await sync.run(budget: .background) { inputs }
        if outcome.changedAnything { sync.hasUnloadedChanges = true }
    }

    /// Everyone this account has mailed, fetched afresh: the screens' copy
    /// may not exist, or be hours old.
    private static func inputs(email: String) async throws -> ReplySync.Inputs {
        let sends = try await SupabaseAPI.fetchSends(userEmail: email, limit: 0)
        let entries = try await SupabaseAPI.fetchActivity(sends: sends)
        var inputs = ReplySync.Inputs(sends: sends, emailByContact: [:])
        for entry in entries {
            let contact = entry.contact
            if !contact.email.isEmpty { inputs.emailByContact[contact.id] = contact.email }
            if !contact.isValid { inputs.excludingContactIDs.insert(contact.id) }
            inputs.people[contact.id] = .init(name: contact.displayName, company: entry.company)
        }
        return inputs
    }
}

/// Tells of replies and bounces a check found while the app wasn't on
/// screen — in the background, or carrying on after the app was left. Every
/// time: one notification per reply, and one for the bounces a check found.
/// With the app open, Activity already shows them.
@MainActor
enum CheckNotifier {
    nonisolated static let laneKey = "lane"

    static func notify(_ outcome: ReplySync.Outcome) {
        guard UIApplication.shared.applicationState != .active, outcome.foundAnything else { return }
        let center = UNUserNotificationCenter.current()
        for reply in outcome.newReplies {
            let content = UNMutableNotificationContent()
            content.title = "\(reply.name) replied"
            content.body = reply.company.map { "\($0) · Open Aurora to read it." } ?? "Open Aurora to read it."
            content.sound = .default
            content.threadIdentifier = "replies"
            content.userInfo = [laneKey: ActivityView.Lane.replied.rawValue]
            // One per person: a reply told again replaces the first.
            center.add(UNNotificationRequest(identifier: "reply-\(reply.contactID)", content: content, trigger: nil))
        }
        if !outcome.newBounces.isEmpty {
            let bounces = outcome.newBounces
            let content = UNMutableNotificationContent()
            content.title = bounces.count == 1
                ? "Mail to \(bounces[0].company ?? bounces[0].name) bounced"
                : "\(bounces.count) mails bounced"
            content.body = Self.list(bounces) + ". Mark them invalid or fix the address in Aurora."
            content.sound = .default
            content.threadIdentifier = "bounces"
            content.userInfo = [laneKey: ActivityView.Lane.bounced.rawValue]
            center.add(UNNotificationRequest(identifier: "bounces-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    /// "Jane Doe at Acme, Raj at Initech and 3 more".
    private static func list(_ found: [ReplySync.Found]) -> String {
        let named = found.prefix(3).map { person in
            person.company.map { "\(person.name) at \($0)" } ?? person.name
        }
        let more = found.count - named.count
        return named.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }
}
