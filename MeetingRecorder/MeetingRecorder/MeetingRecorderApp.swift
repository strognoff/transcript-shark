//
//  MeetingRecorderApp.swift
//  MeetingRecorder
//
//  Menu bar application entry point.
//  - No Dock icon (LSUIElement in Info.plist)
//  - Closing the main window does NOT quit the app
//  - AppState is shared between menu bar and main window via environment
//

import SwiftUI

@main
struct MeetingRecorderApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppState.shared)
        }
        .windowResizability(.contentSize)
        // Prevent app from quitting when the last window closes
        .commands {
            CommandGroup(replacing: .appInfo) { }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock at runtime (belt + suspenders alongside LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        // Create menu bar manager — must happen after app finishes launching
        menuBarManager = MenuBarManager(appState: AppState.shared)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Clicking the Dock icon (if ever shown) brings the window back
        if !hasVisibleWindows {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Never quit when the window is closed — lives in the menu bar
        return false
    }
}
