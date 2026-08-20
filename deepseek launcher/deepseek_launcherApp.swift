//
//  deepseek_launcherApp.swift
//  deepseek launcher
//

import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        HarnessService.shared.stop()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The notification service already suppresses foreground alerts. Keep a
        // defensive no-presentation policy for a focus change race.
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            completionHandler()
        }
    }
}

@main
struct deepseek_launcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("DeepSeek Harness") {
            ContentView(harness: .shared)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 DeepSeek Harness Launcher") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "about-deepseek-harness-launcher")
                }
            }
        }

        Window("关于 DeepSeek Harness Launcher", id: "about-deepseek-harness-launcher") {
            AboutLauncherView(harness: .shared)
        }
        .defaultSize(width: 410, height: 305)
        .windowResizability(.contentSize)
    }
}
