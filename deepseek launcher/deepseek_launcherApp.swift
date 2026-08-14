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

    var body: some Scene {
        WindowGroup("DeepSeek Harness") {
            ContentView(harness: .shared)
        }
    }
}
