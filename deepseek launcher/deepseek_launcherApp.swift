//
//  deepseek_launcherApp.swift
//  deepseek launcher
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        HarnessService.shared.stop()
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
