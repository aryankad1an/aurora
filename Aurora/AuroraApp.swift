//
//  AuroraApp.swift
//  Aurora
//
//  Created by Aryan on 13/08/26.
//

import SwiftUI
import UserNotifications

@main
struct AuroraApp: App {
    /// The notification centre's delegate goes in before the first scene: a tap
    /// on a scheduled-mail notice that launched the app is delivered right away.
    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Writing help through Aurora Writer is the app's one way to have
                // text written, so the system's Writing Tools are off everywhere.
                .writingToolsBehavior(.disabled)
        }
        // Replies and bounces looked for with the app closed (`BackgroundCheck`).
        .backgroundTask(.appRefresh(BackgroundCheck.identifier)) {
            await BackgroundCheck.run()
        }
    }
}
