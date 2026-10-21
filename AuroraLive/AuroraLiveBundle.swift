import SwiftUI
import WidgetKit

/// Aurora's widget extension: the mail queue's Live Activity, a long reply
/// check's, and writing help's while it waits on the Aurora Writer shortcut.
@main
struct AuroraLiveBundle: WidgetBundle {
    var body: some Widget {
        SendLiveActivityWidget()
        CheckLiveActivityWidget()
        WritingLiveActivityWidget()
    }
}
