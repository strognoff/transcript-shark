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
    @Published var permissionError: String? = nil
    @Published var autoRecordingEnabled: Bool = true {
        didSet {
            if autoRecordingEnabled {
                applicationCoordinator.startMonitoring()
            } else {
                applicationCoordinator.stopMonitoring()
            }
        }
    }
    @Published private(set) var cameraBubbleEnabled: Bool
    @Published private(set) var availableCameras: [CameraDevice]
    @Published private(set) var selectedCameraID: String?
    @Published private(set) var captureMode: RecordingCaptureMode
    @Published private(set) var availableCaptureWindows: [SelectableCaptureWindow]
    @Published private(set) var selectedCaptureWindowID: String?

    // MARK: - Meeting detection coordinator
    // Stored as an implicitly unwrapped optional so we can pass `self` during init.
    private(set) var applicationCoordinator: ApplicationCoordinator!

    private let cameraOverlayManager: CameraOverlayManaging
    private let captureWindowProvider: CaptureWindowProviding
    private var cancellables = Set<AnyCancellable>()
    private var constraintRefreshTask: Task<Void, Never>?

    init(
        cameraOverlayManager: CameraOverlayManaging = CameraOverlayManager(),
        captureWindowProvider: CaptureWindowProviding = ScreenCaptureWindowProvider()
    ) {
        let storedCameraID = UserDefaults.standard.string(forKey: "selectedCameraID")
        let storedCaptureMode = RecordingCaptureMode.resolved(from: UserDefaults.standard.string(forKey: kRecordingCaptureModeKey))
        let storedWindowID = UserDefaults.standard.string(forKey: kSelectedCaptureWindowIDKey)

        self.cameraOverlayManager = cameraOverlayManager
        self.captureWindowProvider = captureWindowProvider
        self.cameraBubbleEnabled = false
        self.availableCameras = cameraOverlayManager.availableCameras
        self.selectedCameraID = storedCameraID
        self.captureMode = storedCaptureMode
        self.availableCaptureWindows = []
        self.selectedCaptureWindowID = storedWindowID
        self.cameraOverlayManager.setSelectedCameraID(storedCameraID)
        UserDefaults.standard.removeObject(forKey: "cameraBubbleEnabled")

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

        updateCameraBubbleConstraint()
    }

    deinit {
        constraintRefreshTask?.cancel()
    }

    // MARK: - Actions (forwarded to coordinator)

    func startRecording(application: String = "Manual") async {
        await coordinator.startRecording(application: application, captureScope: effectiveCaptureScope)
    }

    func stopRecording() async {
        await coordinator.stopRecording()
    }

    func reset() {
        coordinator.reset()
    }

    func refreshAvailableCameras() {
        availableCameras = cameraOverlayManager.availableCameras

        if let selectedCameraID,
           !availableCameras.contains(where: { $0.id == selectedCameraID }) {
            setSelectedCameraID(nil)
        }
    }

    func setSelectedCameraID(_ cameraID: String?) {
        selectedCameraID = cameraID
        cameraOverlayManager.setSelectedCameraID(cameraID)

        if let cameraID {
            UserDefaults.standard.set(cameraID, forKey: "selectedCameraID")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedCameraID")
        }

        guard cameraBubbleEnabled else { return }

        Task { @MainActor in
            await setCameraBubbleEnabled(true)
        }
    }

    @discardableResult
    func setCameraBubbleEnabled(_ enabled: Bool) async -> Bool {
        let isEnabled = await cameraOverlayManager.setVisible(enabled)
        cameraBubbleEnabled = isEnabled
        updateCameraBubbleConstraint()

        if enabled && !isEnabled {
            permissionError = "Camera access is required to show the camera bubble."
        } else if permissionError == "Camera access is required to show the camera bubble." {
            permissionError = nil
        }

        return isEnabled
    }

    func toggleCameraBubble() async {
        await setCameraBubbleEnabled(!cameraBubbleEnabled)
    }

    func refreshAvailableCaptureWindows() async {
        availableCaptureWindows = await captureWindowProvider.availableWindows()

        if let selectedCaptureWindowID,
           !availableCaptureWindows.contains(where: { $0.id == selectedCaptureWindowID }) {
            updateCameraBubbleConstraint()
        }
    }

    func setCaptureMode(_ mode: RecordingCaptureMode) {
        captureMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: kRecordingCaptureModeKey)

        if mode == .selectedWindow {
            Task { @MainActor in
                await refreshAvailableCaptureWindows()
                updateCameraBubbleConstraint()
            }
        } else {
            updateCameraBubbleConstraint()
        }
    }

    func setSelectedCaptureWindowID(_ windowID: String?) {
        selectedCaptureWindowID = windowID

        if let windowID {
            UserDefaults.standard.set(windowID, forKey: kSelectedCaptureWindowIDKey)
            if let selectedWindow = availableCaptureWindows.first(where: { $0.id == windowID }) {
                UserDefaults.standard.set(selectedWindow.displayName, forKey: kSelectedCaptureWindowLabelKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: kSelectedCaptureWindowIDKey)
            UserDefaults.standard.removeObject(forKey: kSelectedCaptureWindowLabelKey)
        }

        updateCameraBubbleConstraint()
    }

    // MARK: - Convenience

    var isRecording: Bool { coordinator.isRecording }

    private var effectiveCaptureScope: RecordingCaptureScope {
        guard captureMode == .selectedWindow, let selectedCaptureWindowID else {
            return .wholeScreen
        }
        return .selectedWindow(windowID: selectedCaptureWindowID, fallbackToWholeScreen: true)
    }

    private func updateCameraBubbleConstraint() {
        constraintRefreshTask?.cancel()
        constraintRefreshTask = nil

        guard cameraBubbleEnabled,
              captureMode == .selectedWindow,
              let selectedCaptureWindowID else {
            cameraOverlayManager.setMovementConstraint(nil)
            return
        }

        constraintRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rect = await captureWindowProvider.constraintRect(for: selectedCaptureWindowID)
                guard captureMode == .selectedWindow,
                      self.selectedCaptureWindowID == selectedCaptureWindowID,
                      cameraBubbleEnabled else {
                    cameraOverlayManager.setMovementConstraint(nil)
                    return
                }
                cameraOverlayManager.setMovementConstraint(rect)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
