//
//  MeetingRecorderApp.swift
//  MeetingRecorder
//
//  Menu bar application. The main window is managed entirely by AppDelegate
//  via NSWindowController so it can be reliably recreated after being closed.
//  SwiftUI WindowGroup is NOT used — it cannot reopen a window once closed.
//

import SwiftUI
import AppKit
import OSLog

@main
struct MeetingRecorderApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // No WindowGroup — AppDelegate creates and manages the window directly.
    var body: some Scene {
        Settings { EmptyView() }   // keeps @main happy; no real settings scene yet
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarManager: MenuBarManager?
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Listen for show-window requests from MenuBarManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showMainWindow),
            name: .showMainWindow,
            object: nil
        )

        // Create the main window controller (does not show yet)
        windowController = MainWindowController()

        // Create the menu bar
        menuBarManager = MenuBarManager(appState: AppState.shared)

        // Show the window on first launch
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Called by MenuBarManager — always works regardless of window state.
    @objc func showMainWindow() {
        guard let window = windowController?.window else { return }
        // For .accessory policy apps, orderFrontRegardless is required —
        // makeKeyAndOrderFront alone does nothing when the app has no Dock icon.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Main Window Controller

final class MainWindowController: NSWindowController, NSWindowDelegate {

    init() {
        // Build the window in code — no XIB needed
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Recorder"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false   // ← key: keeps window alive after close

        // Embed the SwiftUI ContentView
        let contentView = ContentView()
            .environmentObject(AppState.shared)
        window.contentView = NSHostingView(rootView: contentView)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Closing hides the window rather than destroying it
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let log = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "MainWindowController")
        log.info("windowShouldClose called — hiding window")
        sender.orderOut(nil)
        return false   // prevent deallocation
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let showMainWindow = Notification.Name("com.transcript-shark.showMainWindow")
}
