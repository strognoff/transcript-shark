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

// MARK: - Summary Service Tests

struct SummaryServiceTests {

    @Test func throwsExecutableNotFoundForBogusPath() async throws {
        // Override the UserDefaults key to point at a non-existent binary
        UserDefaults.standard.set("/nonexistent/tabnine", forKey: kTabnineCLIPathKey)
        defer { UserDefaults.standard.removeObject(forKey: kTabnineCLIPathKey) }

        let service = TabnineSummaryService()
        await #expect(throws: SummaryError.self) {
            _ = try await service.summarise(transcript: "Hello world")
        }
    }

    @Test func throwsNoOutputWhenBinaryProducesNothing() async throws {
        // /usr/bin/true exits 0 but writes nothing to stdout
        UserDefaults.standard.set("/usr/bin/true", forKey: kTabnineCLIPathKey)
        defer { UserDefaults.standard.removeObject(forKey: kTabnineCLIPathKey) }

        let service = TabnineSummaryService()
        do {
            _ = try await service.summarise(transcript: "Some transcript")
            Issue.record("Expected noOutput error but got success")
        } catch SummaryError.noOutput {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
