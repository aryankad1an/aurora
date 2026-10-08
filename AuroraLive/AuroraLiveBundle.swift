import SwiftUI
import WidgetKit

/// Aurora's widget extension: for now, only the mail queue's Live Activity.
@main
struct AuroraLiveBundle: WidgetBundle {
    var body: some Widget {
        SendLiveActivityWidget()
    }
}
