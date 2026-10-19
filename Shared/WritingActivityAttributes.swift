import ActivityKit
import Foundation

/// Writing help's Live Activity, shared by the app (which starts and ends it)
/// and the widget extension (which draws it). Up only while a request is out
/// with the user's Aurora Writer shortcut: the app is behind Shortcuts then, so
/// the Dynamic Island is where it says it's still waiting for the answer.
nonisolated struct WritingActivityAttributes: ActivityAttributes {
    /// The theme's accent when the request went out.
    var accent: SendActivityAttributes.RGB

    struct ContentState: Codable, Hashable {
        /// What was asked: "Proofread", "Make it more specific to Stripe".
        var request: String
        /// When it went to Shortcuts, for the time it's been writing.
        var startedAt: Date
    }
}
