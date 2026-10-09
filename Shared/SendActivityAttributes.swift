import ActivityKit
import Foundation

/// The mail queue's Live Activity, shared by the app (which starts and updates
/// it) and the widget extension (which draws it on the Lock Screen and in the
/// Dynamic Island).
///
/// One activity covers the queue — batch after batch, through pauses and
/// retries, and a scheduled batch while it waits for its time — rather than one
/// per batch, so a long send is one thing on the Lock Screen that keeps
/// counting, not a pile of finished ones.
nonisolated struct SendActivityAttributes: ActivityAttributes {
    /// The theme's colours when the run started. The extension can't read the
    /// app's theme, so they travel with the activity.
    var accent: RGB
    var reply: RGB
    var attention: RGB
    /// The theme's mark, drawn beside the title.
    var mark: String

    struct RGB: Codable, Hashable {
        var red: Double
        var green: Double
        var blue: Double
    }

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            /// A mail is on its way.
            case sending
            /// Gmail asked to slow down; the run carries on at `resumesAt`.
            case waiting
            /// Pause was tapped; the mail in flight is finishing.
            case pausing
            /// Stopped with mail still to go.
            case paused
            /// Nothing left in this run.
            case done
            /// A scheduled batch waiting for `startsAt`. Once that has passed
            /// it's ready, and the activity offers Send Now.
            case scheduled
        }

        var phase: Phase
        /// Who it's to, by company: the company the mail on its way (or next)
        /// is to — "ACKO Insurance" — else the batch's, "ACKO Insurance and 5
        /// more". Not the batch's name, which is often the rule that picked it.
        var title: String
        var sent: Int
        var failed: Int
        var total: Int
        /// Who the mail on its way is to (or, while waiting, the one that
        /// goes next): their name, address and company.
        var recipient: String?
        var recipientEmail: String?
        var company: String?
        /// When a rate-limit wait ends, or a paused batch carries on by itself.
        var resumesAt: Date?
        /// A few words on why it's waiting or stopped: "Connection lost".
        var note: String?
        /// The batch, for the activity's Send Now link.
        var batchID: String?
        /// When a scheduled batch is due.
        var startsAt: Date?

        var done: Int { sent + failed }
        var toGo: Int { max(0, total - done) }
        var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }
    }
}
