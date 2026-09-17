//
//  MeetingRecorderTests.swift
//  MeetingRecorderTests
//
//  Milestone 2 — Unit tests for RecordingCoordinator state transitions
//  and RecordingSession model.
//

import Testing
import Foundation
import CoreGraphics
@testable import MeetingRecorder

// MARK: - Mock AudioCaptureService

@MainActor
final class MockAudioCaptureService: AudioCaptureService {

    let outputURL: URL
    var startCalled = false
    var stopCalled = false
    var shouldThrowOnStart = false
    var shouldThrowOnStop = false

    init(outputURL: URL = URL(fileURLWithPath: "/tmp/test_recording.mp4")) {
        self.outputURL = outputURL
    }

    func start() async throws {
        startCalled = true
        if shouldThrowOnStart {
            throw MockError.startFailed
        }
    }

    func stop() async throws {
        stopCalled = true
        if shouldThrowOnStop {
            throw MockError.stopFailed
        }
    }

    enum MockError: LocalizedError {
        case startFailed, stopFailed
        var errorDescription: String? {
            switch self {
            case .startFailed: return "Mock start failed"
            case .stopFailed:  return "Mock stop failed"
            }
        }
    }
}

// MARK: - Mock CameraOverlayManager

@MainActor
final class MockCameraOverlayManager: CameraOverlayManaging {

    var isVisible = false
    var availableCameras: [CameraDevice] = [
        CameraDevice(id: "built-in", localizedName: "Built-in Camera"),
        CameraDevice(id: "usb", localizedName: "USB Camera")
    ]
    var selectedCameraID: String?
    var requestedStates: [Bool] = []
    var shouldShowSuccessfully = true
    var movementConstraints: [CGRect?] = []

    func setSelectedCameraID(_ cameraID: String?) {
        selectedCameraID = cameraID
    }

    func setMovementConstraint(_ rect: CGRect?) {
        movementConstraints.append(rect)
    }

    func setVisible(_ visible: Bool) async -> Bool {
        requestedStates.append(visible)
        if visible {
            isVisible = shouldShowSuccessfully
        } else {
            isVisible = false
        }
        return isVisible
    }

    func hide() {
        isVisible = false
    }
}

// MARK: - Mock CaptureWindowProvider

@MainActor
final class MockCaptureWindowProvider: CaptureWindowProviding {
    var windows: [SelectableCaptureWindow] = [
        SelectableCaptureWindow(
            id: "window-1",
            title: "Planning",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            frame: CGRect(x: 100, y: 120, width: 900, height: 700)
        )
    ]
    var rectsByID: [String: CGRect] = [
        "window-1": CGRect(x: 100, y: 120, width: 900, height: 700)
    ]

    func availableWindows() async -> [SelectableCaptureWindow] {
        windows
    }

    func constraintRect(for windowID: String) async -> CGRect? {
        rectsByID[windowID]
    }
}

// MARK: - AppState Camera Bubble Tests

@Suite(.serialized)
@MainActor
struct AppStateCameraBubbleTests {

    @Test func cameraBubbleCanBeEnabledAndDisabled() async {
        let defaultsKey = "cameraBubbleEnabled"
        UserDefaults.standard.set(true, forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let mock = MockCameraOverlayManager()
        let appState = AppState(cameraOverlayManager: mock)

        #expect(!appState.cameraBubbleEnabled)
        #expect(UserDefaults.standard.object(forKey: defaultsKey) == nil)
        #expect(mock.requestedStates.isEmpty)

        let enabled = await appState.setCameraBubbleEnabled(true)
        #expect(enabled)
        #expect(appState.cameraBubbleEnabled)
        #expect(UserDefaults.standard.object(forKey: defaultsKey) == nil)
        #expect(mock.requestedStates == [true])

        let disabled = await appState.setCameraBubbleEnabled(false)
        #expect(!disabled)
        #expect(!appState.cameraBubbleEnabled)
        #expect(UserDefaults.standard.object(forKey: defaultsKey) == nil)
        #expect(mock.requestedStates == [true, false])
    }

    @Test func cameraBubbleEnableFailureDoesNotPersistEnabledState() async {
        let defaultsKey = "cameraBubbleEnabled"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let mock = MockCameraOverlayManager()
        mock.shouldShowSuccessfully = false
        let appState = AppState(cameraOverlayManager: mock)

        let enabled = await appState.setCameraBubbleEnabled(true)

        #expect(!enabled)
        #expect(!appState.cameraBubbleEnabled)
        #expect(UserDefaults.standard.object(forKey: defaultsKey) == nil)
        #expect(appState.permissionError == "Camera access is required to show the camera bubble.")
    }

    @Test func selectedCameraIsPersistedAndAppliedToOverlayManager() {
        let defaultsKey = "selectedCameraID"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let mock = MockCameraOverlayManager()
        let appState = AppState(cameraOverlayManager: mock)

        appState.setSelectedCameraID("usb")

        #expect(appState.selectedCameraID == "usb")
        #expect(mock.selectedCameraID == "usb")
        #expect(UserDefaults.standard.string(forKey: defaultsKey) == "usb")
    }

    @Test func selectingCameraRestartsVisibleBubble() async {
        let bubbleKey = "cameraBubbleEnabled"
        let cameraKey = "selectedCameraID"
        UserDefaults.standard.removeObject(forKey: bubbleKey)
        UserDefaults.standard.removeObject(forKey: cameraKey)
        defer {
            UserDefaults.standard.removeObject(forKey: bubbleKey)
            UserDefaults.standard.removeObject(forKey: cameraKey)
        }

        let mock = MockCameraOverlayManager()
        let appState = AppState(cameraOverlayManager: mock)

        await appState.setCameraBubbleEnabled(true)
        appState.setSelectedCameraID("usb")
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(appState.cameraBubbleEnabled)
        #expect(appState.selectedCameraID == "usb")
        #expect(mock.selectedCameraID == "usb")
        #expect(mock.requestedStates == [true, true])
    }

    @Test func refreshAvailableCamerasClearsUnavailableSelection() {
        let defaultsKey = "selectedCameraID"
        UserDefaults.standard.set("missing-camera", forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let mock = MockCameraOverlayManager()
        let appState = AppState(cameraOverlayManager: mock)

        appState.refreshAvailableCameras()

        #expect(appState.selectedCameraID == nil)
        #expect(mock.selectedCameraID == nil)
        #expect(UserDefaults.standard.string(forKey: defaultsKey) == nil)
    }

    @Test func selectedWindowModeAppliesCameraConstraintWhenBubbleIsVisible() async throws {
        let captureModeKey = kRecordingCaptureModeKey
        let selectedWindowKey = kSelectedCaptureWindowIDKey
        UserDefaults.standard.removeObject(forKey: captureModeKey)
        UserDefaults.standard.removeObject(forKey: selectedWindowKey)
        defer {
            UserDefaults.standard.removeObject(forKey: captureModeKey)
            UserDefaults.standard.removeObject(forKey: selectedWindowKey)
        }

        let overlay = MockCameraOverlayManager()
        let provider = MockCaptureWindowProvider()
        let appState = AppState(cameraOverlayManager: overlay, captureWindowProvider: provider)

        await appState.refreshAvailableCaptureWindows()
        appState.setCaptureMode(.selectedWindow)
        appState.setSelectedCaptureWindowID("window-1")
        await appState.setCameraBubbleEnabled(true)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(appState.captureMode == .selectedWindow)
        #expect(UserDefaults.standard.string(forKey: captureModeKey) == RecordingCaptureMode.selectedWindow.rawValue)
        #expect(UserDefaults.standard.string(forKey: selectedWindowKey) == "window-1")
        #expect(overlay.movementConstraints.contains(CGRect(x: 100, y: 120, width: 900, height: 700)))
    }

    @Test func wholeScreenModeClearsCameraConstraint() async throws {
        let overlay = MockCameraOverlayManager()
        let provider = MockCaptureWindowProvider()
        let appState = AppState(cameraOverlayManager: overlay, captureWindowProvider: provider)

        await appState.refreshAvailableCaptureWindows()
        appState.setCaptureMode(.selectedWindow)
        appState.setSelectedCaptureWindowID("window-1")
        await appState.setCameraBubbleEnabled(true)
        try await Task.sleep(nanoseconds: 100_000_000)

        appState.setCaptureMode(.wholeScreen)

        #expect(appState.captureMode == .wholeScreen)
        #expect(overlay.movementConstraints.contains { $0 == nil })
    }

}

// MARK: - AudioCapture Tests

struct AudioCaptureTests {

    @Test func tccDeclinedMessageIsTreatedAsPermissionError() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"]
        )

        #expect(AudioCapture.isScreenCapturePermissionError(error))
    }
}

// MARK: - RecordingSession Tests

@MainActor
struct RecordingSessionTests {

    @Test func sessionHasCorrectDefaults() {
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let session = RecordingSession(outputURL: url)

        #expect(session.endedAt == nil)
        #expect(session.duration == nil)
        #expect(session.meetingApplication == "Manual")
        #expect(session.outputURL == url)
    }

    @Test func finishedSessionHasDuration() {
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let start = Date()
        let session = RecordingSession(startedAt: start, outputURL: url)

        let finished = session.finished(at: start.addingTimeInterval(120))

        #expect(finished.duration != nil)
        #expect(abs((finished.duration ?? 0) - 120) < 1)
    }

    @Test func finishedSessionPreservesID() {
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let session = RecordingSession(outputURL: url)
        let finished = session.finished()
        #expect(session.id == finished.id)
    }
}

// MARK: - RecordingCoordinator Tests

@MainActor
struct RecordingCoordinatorTests {

    func makeCoordinator() -> (RecordingCoordinator, MockAudioCaptureService, CapturedScopeBox) {
        let mock = MockAudioCaptureService()
        let box = CapturedScopeBox()
        let coordinator = RecordingCoordinator(makeCaptureService: { _, scope in
            box.scope = scope
            return mock
        })
        return (coordinator, mock, box)
    }

    final class CapturedScopeBox {
        var scope: RecordingCaptureScope?
    }

    @Test func startsInIdleState() {
        let (coordinator, _, _) = makeCoordinator()
        guard case .idle = coordinator.recorderState else {
            Issue.record("Expected idle state")
            return
        }
    }

    @Test func transitionsToRecordingOnStart() async {
        let (coordinator, mock, _) = makeCoordinator()
        await coordinator.startRecording()

        guard case .recording = coordinator.recorderState else {
            Issue.record("Expected recording state, got \(coordinator.recorderState)")
            return
        }
        let startCalled = mock.startCalled
        #expect(startCalled)
    }

    @Test func passesCaptureScopeToFactory() async {
        let (coordinator, _, box) = makeCoordinator()
        await coordinator.startRecording(captureScope: .selectedWindow(windowID: "window-1"))

        #expect(box.scope == .selectedWindow(windowID: "window-1"))
    }

    @Test func defaultsCaptureScopeToWholeScreen() async {
        let (coordinator, _, box) = makeCoordinator()
        await coordinator.startRecording()

        #expect(box.scope == .wholeScreen)
    }

    @Test func transitionsToFinishedOnStop() async {
        let (coordinator, mock, _) = makeCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        guard case .finished = coordinator.recorderState else {
            Issue.record("Expected finished state")
            return
        }
        let stopCalled = mock.stopCalled
        #expect(stopCalled)
    }

    @Test func guardAgainstDoubleStart() async {
        let (coordinator, mock, _) = makeCoordinator()
        await coordinator.startRecording()
        await coordinator.startRecording() // second call — should be ignored

        guard case .recording = coordinator.recorderState else {
            Issue.record("Expected still recording")
            return
        }
        // start should only have been called once
        let startCalledOnce = mock.startCalled
        #expect(startCalledOnce)
    }

    @Test func transitionsToFailedOnStartError() async {
        let mock = MockAudioCaptureService()
        mock.shouldThrowOnStart = true
        let coordinator = RecordingCoordinator(makeCaptureService: { _, _ in mock })

        await coordinator.startRecording()

        guard case .failed = coordinator.recorderState else {
            Issue.record("Expected failed state")
            return
        }
    }

    @Test func resetReturnsToIdle() async {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        coordinator.reset()

        guard case .idle = coordinator.recorderState else {
            Issue.record("Expected idle state after reset")
            return
        }
        let duration = coordinator.duration
        #expect(duration == 0)
    }
}

// MARK: - Speaker Attribution Tests

struct SpeakerAttributionTests {

    // MARK: TranscriptSegment

    @Test func segmentDefaultSpeakerIsUnknown() {
        let seg = TranscriptSegment(startTime: 0, endTime: 1, text: "Hello")
        #expect(seg.speaker == .unknown)
    }

    @Test func segmentRetainsSpeakerMe() {
        let seg = TranscriptSegment(startTime: 0, endTime: 1, text: "Hello", speaker: .me)
        #expect(seg.speaker == .me)
    }

    @Test func segmentRetainsSpeakerThem() {
        let seg = TranscriptSegment(startTime: 1, endTime: 2, text: "Hi there", speaker: .them)
        #expect(seg.speaker == .them)
    }

    // MARK: MarkdownGenerator — speaker-attributed rendering

    @Test func markdownContainsMeLabel() {
        let seg = TranscriptSegment(startTime: 0, endTime: 2, text: "Hello from me", speaker: .me)
        let result = TranscriptResult(text: "Hello from me", segments: [seg], detectedLanguage: nil, duration: 2)
        let session = RecordingSession(outputURL: URL(fileURLWithPath: "/tmp/test.mp4"))
        let md = MarkdownGenerator().generate(session: session, result: result)
        #expect(md.contains("**Me**"), "Markdown should contain **Me** label")
        #expect(md.contains("Hello from me"))
    }

    @Test func markdownContainsThemLabel() {
        let seg = TranscriptSegment(startTime: 0, endTime: 2, text: "Hello from them", speaker: .them)
        let result = TranscriptResult(text: "Hello from them", segments: [seg], detectedLanguage: nil, duration: 2)
        let session = RecordingSession(outputURL: URL(fileURLWithPath: "/tmp/test.mp4"))
        let md = MarkdownGenerator().generate(session: session, result: result)
        #expect(md.contains("**Them**"), "Markdown should contain **Them** label")
        #expect(md.contains("Hello from them"))
    }

    @Test func markdownGroupsConsecutiveSameSpeaker() {
        let segs = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "Word one", speaker: .me),
            TranscriptSegment(startTime: 1, endTime: 2, text: "word two", speaker: .me),
            TranscriptSegment(startTime: 2, endTime: 3, text: "their reply", speaker: .them),
        ]
        let result = TranscriptResult(text: "", segments: segs, detectedLanguage: nil, duration: 3)
        let session = RecordingSession(outputURL: URL(fileURLWithPath: "/tmp/test.mp4"))
        let md = MarkdownGenerator().generate(session: session, result: result)

        // Me label appears exactly once (two consecutive me-segments merged into one block)
        let meCount = md.components(separatedBy: "**Me**").count - 1
        let themCount = md.components(separatedBy: "**Them**").count - 1
        #expect(meCount == 1, "Me label should appear once for consecutive me-segments")
        #expect(themCount == 1, "Them label should appear once")
    }

    @Test func markdownSpeakerLabelChangesOnSpeakerSwitch() {
        let segs = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "I say", speaker: .me),
            TranscriptSegment(startTime: 1, endTime: 2, text: "they say", speaker: .them),
            TranscriptSegment(startTime: 2, endTime: 3, text: "I respond", speaker: .me),
        ]
        let result = TranscriptResult(text: "", segments: segs, detectedLanguage: nil, duration: 3)
        let session = RecordingSession(outputURL: URL(fileURLWithPath: "/tmp/test.mp4"))
        let md = MarkdownGenerator().generate(session: session, result: result)

        let meCount = md.components(separatedBy: "**Me**").count - 1
        let themCount = md.components(separatedBy: "**Them**").count - 1
        #expect(meCount == 2, "Me label should appear twice (two separate me-runs)")
        #expect(themCount == 1)
    }

    @Test func markdownFallsBackToTimestampBucketsForUnknownSpeaker() {
        let segs = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "Hello"),     // speaker: .unknown (default)
            TranscriptSegment(startTime: 61, endTime: 62, text: "World"),
        ]
        let result = TranscriptResult(text: "", segments: segs, detectedLanguage: nil, duration: 62)
        let session = RecordingSession(outputURL: URL(fileURLWithPath: "/tmp/test.mp4"))
        let md = MarkdownGenerator().generate(session: session, result: result)

        // Should use ### timestamp headers, not **Me** / **Them**
        #expect(md.contains("### 00:00"), "Should contain timestamp header for first bucket")
        #expect(md.contains("### 01:01"), "Should contain timestamp header for second bucket")
        #expect(!md.contains("**Me**"))
        #expect(!md.contains("**Them**"))
    }
}

// MARK: - Meeting Mapping Tests

@MainActor
struct MeetingMappingTests {

    @Test func meetingRecordMapsSummaryPromptOverride() {
        let record = MeetingRecord(
            title: "Prompt Test",
            startedAt: Date(timeIntervalSince1970: 1_000),
            recordingPath: "Recordings/test.mp4",
            summaryPromptOverride: "Focus on decisions."
        )

        let meeting = record.toMeeting(baseURL: URL(fileURLWithPath: "/tmp/MeetingRecorder"))

        #expect(meeting.summaryPromptOverride == "Focus on decisions.")
    }
}

// MARK: - Summary Service Tests

@Suite(.serialized)
struct SummaryServiceTests {

    @Test func resolvedSummaryPromptUsesDefaultWhenUnsetOrBlank() {
        UserDefaults.standard.removeObject(forKey: kTabnineSummaryPromptKey)
        defer { UserDefaults.standard.removeObject(forKey: kTabnineSummaryPromptKey) }

        let service = TabnineSummaryService()
        #expect(service.resolvedSummaryPrompt() == kDefaultTabnineSummaryPrompt)

        UserDefaults.standard.set("   \n\t  ", forKey: kTabnineSummaryPromptKey)
        #expect(service.resolvedSummaryPrompt() == kDefaultTabnineSummaryPrompt)
    }

    @Test func resolvedSummaryPromptUsesCustomInstructions() {
        let customPrompt = "Give me only the highlights."
        UserDefaults.standard.set(customPrompt, forKey: kTabnineSummaryPromptKey)
        defer { UserDefaults.standard.removeObject(forKey: kTabnineSummaryPromptKey) }

        let service = TabnineSummaryService()
        #expect(service.resolvedSummaryPrompt() == customPrompt)
    }

    @Test func resolvedSummaryPromptUsesRecordingOverrideBeforeGlobalPrompt() {
        UserDefaults.standard.set("Global prompt", forKey: kTabnineSummaryPromptKey)
        defer { UserDefaults.standard.removeObject(forKey: kTabnineSummaryPromptKey) }

        let service = TabnineSummaryService()

        #expect(service.resolvedSummaryPrompt(override: "  Recording prompt  ") == "Recording prompt")
        #expect(service.resolvedSummaryPrompt(override: " \n\t ") == "Global prompt")
    }

    @Test func tabnineArgumentsUseEffectivePromptWithoutTranscriptArgument() {
        let service = TabnineSummaryService()
        let arguments = service.arguments(for: .tabnine, prompt: "Recording prompt", transcript: "Sensitive transcript")

        #expect(arguments.contains("Recording prompt"))
        #expect(!arguments.contains("Sensitive transcript"))
    }

    @Test func openCodeArgumentsIncludeEffectivePromptAndTranscript() {
        let service = TabnineSummaryService()
        let arguments = service.arguments(for: .openCode, prompt: "Recording prompt", transcript: "Transcript body")

        #expect(arguments.last == "Recording prompt\n\nTranscript:\nTranscript body")
    }

    @Test func resolvedProviderDefaultsToTabnineAndSupportsOpenCode() {
        UserDefaults.standard.removeObject(forKey: kAISummaryProviderKey)
        defer { UserDefaults.standard.removeObject(forKey: kAISummaryProviderKey) }

        let service = TabnineSummaryService()
        #expect(service.resolvedProvider() == .tabnine)

        UserDefaults.standard.set(AISummaryProvider.openCode.rawValue, forKey: kAISummaryProviderKey)
        #expect(service.resolvedProvider() == .openCode)
    }

    @Test func resolvedExecutablePathUsesProviderSpecificDefaultsAndOverrides() {
        UserDefaults.standard.removeObject(forKey: kTabnineCLIPathKey)
        UserDefaults.standard.removeObject(forKey: kOpenCodeCLIPathKey)
        defer {
            UserDefaults.standard.removeObject(forKey: kTabnineCLIPathKey)
            UserDefaults.standard.removeObject(forKey: kOpenCodeCLIPathKey)
        }

        let service = TabnineSummaryService()
        #expect(service.resolvedExecutablePath(for: .tabnine) == kDefaultTabnineCLIPath)
        #expect(service.resolvedExecutablePath(for: .openCode) == kDefaultOpenCodeCLIPath)

        UserDefaults.standard.set("/tmp/tabnine", forKey: kTabnineCLIPathKey)
        UserDefaults.standard.set("/tmp/opencode", forKey: kOpenCodeCLIPathKey)
        #expect(service.resolvedExecutablePath(for: .tabnine) == "/tmp/tabnine")
        #expect(service.resolvedExecutablePath(for: .openCode) == "/tmp/opencode")
    }

    @Test func throwsExecutableNotFoundForBogusPath() async throws {
        // Override the UserDefaults key to point at a non-existent binary
        UserDefaults.standard.set("/nonexistent/tabnine", forKey: kTabnineCLIPathKey)
        UserDefaults.standard.removeObject(forKey: kAISummaryProviderKey)
        defer {
            UserDefaults.standard.removeObject(forKey: kTabnineCLIPathKey)
            UserDefaults.standard.removeObject(forKey: kAISummaryProviderKey)
        }

        let service = TabnineSummaryService()
        let recordingURL = URL(fileURLWithPath: "/tmp/test_recording.mp4")
        await #expect(throws: SummaryError.self) {
            _ = try await service.summarise(transcript: "Hello world", recordingURL: recordingURL)
        }
    }

    @Test func throwsNoOutputWhenBinaryProducesNothing() async throws {
        // /usr/bin/true exits 0 but writes nothing to stdout
        UserDefaults.standard.set("/usr/bin/true", forKey: kTabnineCLIPathKey)
        UserDefaults.standard.removeObject(forKey: kAISummaryProviderKey)
        defer {
            UserDefaults.standard.removeObject(forKey: kTabnineCLIPathKey)
            UserDefaults.standard.removeObject(forKey: kAISummaryProviderKey)
        }

        let service = TabnineSummaryService()
        let recordingURL = URL(fileURLWithPath: "/tmp/test_recording.mp4")
        do {
            _ = try await service.summarise(transcript: "Some transcript", recordingURL: recordingURL)
            Issue.record("Expected noOutput error but got success")
        } catch SummaryError.noOutput(.tabnine) {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
