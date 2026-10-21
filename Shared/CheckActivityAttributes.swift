import ActivityKit
import Foundation

/// A reply check's Live Activity, shared by the app (which starts and updates
/// it) and the widget extension (which draws it on the Lock Screen and in the
/// Dynamic Island): which step the check is on and how far through, then what
/// it found.
nonisolated struct CheckActivityAttributes: ActivityAttributes {
    /// The app's colours, which the extension can't read for itself.
    var accent: SendActivityAttributes.RGB
    var reply: SendActivityAttributes.RGB
    var attention: SendActivityAttributes.RGB

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case checking
            /// Finished: `replies` and `bounced` say what it found.
            case done
            /// Stopped partway; `note` says why.
            case stopped
        }

        var phase: Phase
        /// "Checking threads for replies".
        var label: String
        /// Which step, counting from 1, and how many there are.
        var step: Int
        var steps: Int
        /// How far through the whole check, 0...1.
        var overall: Double
        /// "12 of 80 mails", while a step knows how much it has to do.
        var detail: String?
        var replies: Int
        var bounced: Int
        var note: String?
    }
}
