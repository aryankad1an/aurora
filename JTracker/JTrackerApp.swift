//
//  JTrackerApp.swift
//  JTracker
//
//  Created by Aryan on 13/08/26.
//

import SwiftUI
import UserNotifications

@main
struct JTrackerApp: App {
    /// The notification centre's delegate goes in before the first scene: a tap
    /// on a scheduled-mail notice that launched the app is delivered right away.
    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
