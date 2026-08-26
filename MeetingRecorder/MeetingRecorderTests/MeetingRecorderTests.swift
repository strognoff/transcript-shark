//
//  MeetingRecorderTests.swift
//  MeetingRecorderTests
//
//  Milestone 2 — Unit tests for RecordingCoordinator state transitions
//  and RecordingSession model.
//

import Testing
import Foundation
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

    func makeCoordinator() -> (RecordingCoordinator, MockAudioCaptureService) {
        let mock = MockAudioCaptureService()
        let coordinator = RecordingCoordinator(makeCaptureService: { _ in mock })
        return (coordinator, mock)
    }

    @Test func startsInIdleState() {
        let (coordinator, _) = makeCoordinator()
        guard case .idle = coordinator.recorderState else {
            Issue.record("Expected idle state")
            return
        }
    }

    @Test func transitionsToRecordingOnStart() async {
        let (coordinator, mock) = makeCoordinator()
        await coordinator.startRecording()

        guard case .recording = coordinator.recorderState else {
            Issue.record("Expected recording state, got \(coordinator.recorderState)")
            return
        }
        let startCalled = mock.startCalled
        #expect(startCalled)
    }

    @Test func transitionsToFinishedOnStop() async {
        let (coordinator, mock) = makeCoordinator()
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
        let (coordinator, mock) = makeCoordinator()
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
        let coordinator = RecordingCoordinator(makeCaptureService: { _ in mock })

        await coordinator.startRecording()

        guard case .failed = coordinator.recorderState else {
            Issue.record("Expected failed state")
            return
        }
    }

    @Test func resetReturnsToIdle() async {
        let (coordinator, _) = makeCoordinator()
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
