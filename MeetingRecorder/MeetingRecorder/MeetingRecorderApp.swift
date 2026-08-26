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
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock at runtime (belt + suspenders alongside LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        // Track the main window as soon as it appears
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // Create menu bar manager — must happen after app finishes launching
        menuBarManager = MenuBarManager(appState: AppState.shared)
    }

    @objc private func handleWindowBecameKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window.canBecomeMain {
            mainWindow = window
        }
    }

    // Called by MenuBarManager.openApp() via notification
    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window was fully deallocated — ask SwiftUI to recreate it
            NSApp.sendAction(#selector(NSDocument.makeWindowControllers), to: nil, from: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
