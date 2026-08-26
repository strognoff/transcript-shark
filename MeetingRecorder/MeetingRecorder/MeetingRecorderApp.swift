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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarManager: MenuBarManager?
    private var windowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Listen for show-window requests from MenuBarManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showMainWindow),
            name: .showMainWindow,
            object: nil
        )

        // Listen for show-settings requests from MenuBarManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings),
            name: .showSettings,
            object: nil
        )

        // Sleep / wake — stop recording cleanly before sleep, resume monitoring on wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        // Create the main window controller (does not show yet)
        windowController = MainWindowController()

        // Create the menu bar
        menuBarManager = MenuBarManager(appState: AppState.shared)

        // Show onboarding on first launch, otherwise open main window directly
        let onboardingCompleted = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if !onboardingCompleted {
            showOnboarding()
        } else {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.isRecording else { return .terminateNow }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Stop recording and quit?"
            alert.informativeText = "The current recording will be saved before quitting."
            alert.addButton(withTitle: "Stop Recording and Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { @MainActor in
                    await AppState.shared.stopRecording()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    // MARK: - Sleep / Wake handlers

    @objc private func systemWillSleep() {
        let log = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AppDelegate")
        log.info("AppDelegate: system will sleep — stopping recording and monitoring")
        if AppState.shared.isRecording {
            Task { @MainActor in
                await AppState.shared.stopRecording()
            }
        }
        AppState.shared.applicationCoordinator.stopMonitoring()
    }

    @objc private func systemDidWake() {
        let log = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AppDelegate")
        log.info("AppDelegate: system did wake — resuming monitoring")
        if AppState.shared.autoRecordingEnabled {
            AppState.shared.applicationCoordinator.startMonitoring()
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        guard let window = windowController?.window else { return }
        let onboardingView = OnboardingView {
            // Onboarding complete — dismiss sheet and show main window
            window.endSheet(window.attachedSheet ?? NSWindow())
            self.showMainWindow()
        }
        let hostingVC = NSHostingController(rootView: onboardingView)
        let sheetWindow = NSWindow(contentViewController: hostingVC)
        sheetWindow.styleMask = [.titled, .fullSizeContentView]
        sheetWindow.titleVisibility = .hidden
        sheetWindow.titlebarAppearsTransparent = true

        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.beginSheet(sheetWindow)
    }

    /// Called by MenuBarManager and keyboard shortcut — always works regardless of window state.
    @objc func showMainWindow() {
        guard let window = windowController?.window else { return }
        // For .accessory policy apps, orderFrontRegardless is required —
        // makeKeyAndOrderFront alone does nothing when the app has no Dock icon.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens (or brings to front) the Settings window.
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Main Window Controller

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {

    init() {
        // defer: true prevents the window from triggering layout before contentView is set
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Meeting Recorder"
        window.isReleasedWhenClosed = false   // ← key: keeps window alive after close

        super.init(window: window)

        // Set contentView AFTER super.init so AppKit's window is fully initialised
        // before SwiftUI triggers its first layout pass — prevents the
        // "not legal to call -layoutSubtreeIfNeeded" warning.
        window.contentView = NSHostingView(rootView:
            ContentView().environmentObject(AppState.shared)
        )
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MainWindow")
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

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.contentView = NSHostingView(rootView: SettingsView())
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let showMainWindow = Notification.Name("com.transcript-shark.showMainWindow")
    static let showSettings   = Notification.Name("com.transcript-shark.showSettings")
}
