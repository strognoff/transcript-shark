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
    @Published var autoRecordingEnabled: Bool = true

    private var cancellables = Set<AnyCancellable>()

    private init() {
        coordinator.$recorderState
            .assign(to: &$recorderState)
        coordinator.$duration
            .assign(to: &$duration)
    }

    // MARK: - Actions (forwarded to coordinator)

    func startRecording() async {
        await coordinator.startRecording()
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
