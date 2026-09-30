import Foundation
import Observation
import UserNotifications

/// The notification a scheduled batch leaves with the system.
///
/// iOS won't wake an app at a set time to do work, but it will show a
/// notification then — the same thing Reminders relies on. So scheduling hands
/// iOS a notice for the batch's time; tapping it opens the app straight onto the
/// batch's summary, where it's sent with one tap.
enum ScheduledMailNotifier {
    /// Ask once, the first time something is scheduled.
    @discardableResult
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    /// Turned off in Settings — so a scheduled batch will get no reminder.
    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Leave (or replace) the notice for `batch`'s time.
    static func schedule(_ batch: MailBatch) {
        guard let date = batch.scheduledFor, date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Scheduled mail is ready"
        let count = batch.pending
        content.body = "\(count == 1 ? "1 mail" : "\(count) mails") · \(batch.title). Tap to review and send."
        content.sound = .default
        content.userInfo = [batchKey: batch.id.uuidString]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(identifier: batch.id.uuidString, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    nonisolated fileprivate static let batchKey = "batchID"
}

/// Receives taps on scheduled-mail notifications. Installed as the notification
/// centre's delegate when the app launches — before any tap that launched it is
/// delivered — and holds the tapped batch until the queue is ready for it.
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = NotificationRouter()

    /// The batch whose notification was tapped, waiting to be shown.
    @MainActor var openedBatchID: UUID?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo[ScheduledMailNotifier.batchKey] as? String)
            .flatMap(UUID.init(uuidString:))
        guard let id else { return }
        await MainActor.run { NotificationRouter.shared.openedBatchID = id }
    }

    /// In the app already: the summary sheet appears by itself when the time
    /// comes, so the banner would only say the same thing twice.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
