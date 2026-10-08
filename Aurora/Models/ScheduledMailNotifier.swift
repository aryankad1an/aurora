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

    /// Leave a notice for when a batch stopped by Gmail's sending limit
    /// carries on — by itself if the app is open, on the next open if not.
    static func scheduleResume(_ batch: MailBatch, at date: Date) {
        guard date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Gmail's sending limit has passed"
        content.body = "\(batch.pending == 1 ? "1 mail" : "\(batch.pending) mails") still to go · \(batch.title). Open Aurora to carry on sending."
        content.sound = .default
        content.userInfo = [batchKey: batch.id.uuidString]
        let request = UNNotificationRequest(identifier: resumeID(batch.id), content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow,
                                                                                      repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    static func cancelResume(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [resumeID(id)])
        center.removeDeliveredNotifications(withIdentifiers: [resumeID(id)])
    }

    private static func resumeID(_ id: UUID) -> String { id.uuidString + "-resume" }

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

    /// The completion-handler form, answered on the main thread — not the
    /// `async` form. Swift finishes an `async` delegate call on a background
    /// thread, and the completion it then hands to UIKit is what brings the app
    /// to the front: run off the main thread it trips a UIKit assertion, and the
    /// app that the tap had just opened crashes straight back to the Home
    /// Screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo[ScheduledMailNotifier.batchKey] as? String)
            .flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id { NotificationRouter.shared.openedBatchID = id }
            }
            completionHandler()
        }
    }

    /// In the app already: the summary sheet appears by itself when the time
    /// comes, so the banner would only say the same thing twice.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([]) }
    }
}
