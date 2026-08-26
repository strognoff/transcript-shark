//
//  AppState.swift
//  MeetingRecorder
//
//  Single source of truth shared between the menu bar and the main window.
//  Both layers observe this object — neither owns RecordingCoordinator directly.
//

import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - Shared singleton (injected via .environmentObject in App)
    static let shared = AppState()

    // MARK: - Coordinator (the only place it lives)
    let coordinator = RecordingCoordinator()

    // MARK: - Forwarded published state (convenient for menu bar)
    @Published private(set) var recorderState: RecorderState = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published var autoRecordingEnabled: Bool = true {
        didSet {
            if autoRecordingEnabled {
                applicationCoordinator.startMonitoring()
            } else {
                applicationCoordinator.stopMonitoring()
            }
        }
    }

    // MARK: - Meeting detection coordinator
    // Stored as an implicitly unwrapped optional so we can pass `self` during init.
    private(set) var applicationCoordinator: ApplicationCoordinator!

    private var cancellables = Set<AnyCancellable>()

    private init() {
        coordinator.$recorderState
            .assign(to: &$recorderState)
        coordinator.$duration
            .assign(to: &$duration)

        // Wire up the detection coordinator after stored properties are set.
        applicationCoordinator = ApplicationCoordinator(appState: self)

        // Start monitoring immediately if auto-recording is enabled.
        if autoRecordingEnabled {
            applicationCoordinator.startMonitoring()
        }
    }

    // MARK: - Actions (forwarded to coordinator)

    func startRecording(application: String = "Manual") async {
        await coordinator.startRecording(application: application)
    }

    func stopRecording() async {
        await coordinator.stopRecording()
    }

    func reset() {
        coordinator.reset()
    }

    // MARK: - Convenience

    var isRecording: Bool { coordinator.isRecording }
}
