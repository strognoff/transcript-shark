//
//  MenuBarManager.swift
//  MeetingRecorder
//
//  Owns the NSStatusItem and rebuilds the menu whenever AppState changes.
//
//  Icon states (text-based for accessibility — no colour dependency):
//    ○  Idle / monitoring
//    ●  Recording
//    ◌  Transcribing (Milestone 4)
//    ⊘  Disabled
//    !  Error
//

import AppKit
import Combine
import OSLog

@MainActor
final class MenuBarManager {

    private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "MenuBarManager")

    // MARK: - State

    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var timerItem: NSMenuItem?   // updated every second while recording

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
        setupStatusItem()
        observeState()
        logger.info("MenuBarManager: initialised")
    }

    // MARK: - Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "○"
        item.button?.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        item.button?.toolTip = "Meeting Recorder"
        statusItem = item
        rebuildMenu()
    }

    private func observeState() {
        appState.$recorderState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.rebuildMenu() }
            .store(in: &cancellables)

        appState.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTimerItem() }
            .store(in: &cancellables)

        appState.$autoRecordingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.rebuildMenu() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .potentialMeetingDetected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showDetectingState() }
            .store(in: &cancellables)
    }

    private func showDetectingState() {
        // Briefly show a "detecting" icon if we are idle (not yet recording).
        guard case .idle = appState.recorderState else { return }
        statusItem?.button?.title = "◎"
        // Revert to normal idle icon after 4 seconds if still idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, case .idle = self.appState.recorderState else { return }
            self.statusItem?.button?.title = "○"
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        let symbol: String
        switch appState.recorderState {
        case .idle:                   symbol = "○"
        case .recording:              symbol = "●"
        case .finished:               symbol = "○"
        case .failed:                 symbol = "!"
        }
        statusItem?.button?.title = symbol
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        switch appState.recorderState {

        case .idle:
            idleMenuItems(menu)

        case .recording(let session):
            recordingMenuItems(menu, session: session)

        case .finished(let session):
            finishedMenuItems(menu, session: session)

        case .failed(let error):
            failedMenuItems(menu, error: error)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open App",   action: #selector(openApp),   keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…",  action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit",       action: #selector(quitApp),   keyEquivalent: "q").target = self

        statusItem?.menu = menu
    }

    // MARK: - Menu sections per state

    private func idleMenuItems(_ menu: NSMenu) {
        let header = NSMenuItem(title: "○  Meeting Recorder", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let autoItem = NSMenuItem(
            title: "Auto Recording: \(appState.autoRecordingEnabled ? "ON" : "OFF")",
            action: #selector(toggleAutoRecording),
            keyEquivalent: ""
        )
        autoItem.target = self
        menu.addItem(autoItem)

        let startItem = NSMenuItem(title: "Start Recording Manually", action: #selector(startRecording), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
    }

    private func recordingMenuItems(_ menu: NSMenu, session: RecordingSession) {
        let elapsed = formatDuration(appState.duration)
        let timerItem = NSMenuItem(title: "●  Recording — \(session.meetingApplication) / \(elapsed)", action: nil, keyEquivalent: "")
        timerItem.isEnabled = false
        menu.addItem(timerItem)
        self.timerItem = timerItem

        menu.addItem(.separator())

        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        let disableItem = NSMenuItem(
            title: "Disable Auto Recording",
            action: #selector(disableAutoRecording),
            keyEquivalent: ""
        )
        disableItem.target = self
        menu.addItem(disableItem)
    }

    private func finishedMenuItems(_ menu: NSMenu, session: RecordingSession) {
        let header = NSMenuItem(title: "✓  Recording saved", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealLastRecording), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = session.outputURL
        menu.addItem(revealItem)

        let newItem = NSMenuItem(title: "Start Recording Manually", action: #selector(startRecording), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
    }

    private func failedMenuItems(_ menu: NSMenu, error: Error) {
        let header = NSMenuItem(title: "!  Recording failed", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let detail = NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

        menu.addItem(.separator())

        let retryItem = NSMenuItem(title: "Try Again", action: #selector(resetAndRetry), keyEquivalent: "")
        retryItem.target = self
        menu.addItem(retryItem)
    }

    // MARK: - Timer update (hot path — only updates the title, no menu rebuild)

    private func updateTimerItem() {
        guard case .recording(let session) = appState.recorderState else { return }
        timerItem?.title = "●  Recording — \(session.meetingApplication) / \(formatDuration(appState.duration))"
    }

    // MARK: - Actions

    @objc private func startRecording() {
        Task { @MainActor in await appState.startRecording() }
    }

    @objc private func stopRecording() {
        Task { @MainActor in await appState.stopRecording() }
    }

    @objc private func toggleAutoRecording() {
        appState.autoRecordingEnabled.toggle()
        rebuildMenu()
    }

    @objc private func disableAutoRecording() {
        appState.autoRecordingEnabled = false
        rebuildMenu()
    }

    @objc private func resetAndRetry() {
        appState.reset()
        rebuildMenu()
    }

    @objc private func revealLastRecording(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func openApp() {
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    @objc private func quitApp() {
        // If recording, confirm first
        if case .recording = appState.recorderState {
            let alert = NSAlert()
            alert.messageText = "Stop recording and quit?"
            alert.informativeText = "The current recording will be saved before quitting."
            alert.addButton(withTitle: "Stop Recording and Quit")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            Task { @MainActor in
                await appState.stopRecording()
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
