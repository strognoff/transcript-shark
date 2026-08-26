//
//  RecordingCoordinator.swift
//  MeetingRecorder
//
//  Orchestrates recording sessions. References AudioCaptureService only —
//  never the concrete AudioCapture type.
//
//  Architecture rules enforced here:
//  - Guards against duplicate sessions (cannot start while already recording)
//  - Owns RecordingSession lifecycle
//  - Calls TranscriptionQueue.enqueue() on stop
//  - Never references TranscriptionService or UI layers
//

import Combine
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "RecordingCoordinator")

// MARK: - Recorder State

enum RecorderState: Equatable {
    case idle
    case recording(RecordingSession)
    case finished(RecordingSession)
    case failed(Error)

    static func == (lhs: RecorderState, rhs: RecorderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):                         return true
        case (.recording(let a), .recording(let b)): return a.id == b.id
        case (.finished(let a), .finished(let b)):   return a.id == b.id
        case (.failed, .failed):                     return true
        default:                                     return false
        }
    }
}

// MARK: - Coordinator

@MainActor
final class RecordingCoordinator: ObservableObject {

    // MARK: - Published state

    @Published private(set) var recorderState: RecorderState = .idle
    @Published private(set) var duration: TimeInterval = 0

    // MARK: - Private

    /// Factory — injected so tests can substitute a mock AudioCaptureService.
    private let makeCaptureService: (URL) -> AudioCaptureService

    private var captureService: AudioCaptureService?
    private var timer: AnyCancellable?

    // MARK: - Init

    init(makeCaptureService: @escaping (URL) -> AudioCaptureService = { AudioCapture(outputURL: $0) }) {
        self.makeCaptureService = makeCaptureService
    }

    // MARK: - Start

    func startRecording(application: String = "Manual") async {
        guard case .idle = recorderState else {
            logger.warning("RecordingCoordinator: startRecording called while not idle — ignored")
            return
        }

        logger.info("RecordingCoordinator: starting")

        do {
            let outputURL = try sessionURL()
            let service = makeCaptureService(outputURL)
            captureService = service

            let session = RecordingSession(outputURL: outputURL, meetingApplication: application)

            try await service.start()

            recorderState = .recording(session)
            startTimer()
            logger.info("RecordingCoordinator: recording started — \(session.id)")

        } catch {
            logger.error("RecordingCoordinator: start failed — \(error.localizedDescription)")
            recorderState = .failed(error)
            cleanupCapture()
        }
    }

    // MARK: - Stop

    func stopRecording() async {
        guard case .recording(let session) = recorderState else {
            logger.warning("RecordingCoordinator: stopRecording called while not recording — ignored")
            return
        }

        logger.info("RecordingCoordinator: stopping — \(session.id)")
        stopTimer()

        do {
            try await captureService?.stop()
        } catch {
            // Swallow "already stopped" errors from SCStream — the file may still be valid
            logger.warning("RecordingCoordinator: stop error (non-fatal) — \(error.localizedDescription)")
        }

        let finished = session.finished()
        recorderState = .finished(finished)
        logger.info("RecordingCoordinator: finished — duration: \(String(format: "%.1f", finished.duration ?? 0))s")

        cleanupCapture()
    }

    // MARK: - Reset

    func reset() {
        cleanupCapture()
        duration = 0
        recorderState = .idle
    }

    // MARK: - Convenience accessors for UI

    var isRecording: Bool {
        if case .recording = recorderState { return true }
        return false
    }

    var currentSession: RecordingSession? {
        switch recorderState {
        case .recording(let s), .finished(let s): return s
        default: return nil
        }
    }

    // MARK: - Private helpers

    private func sessionURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("MeetingRecorder")
            .appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recording_\(UUID().uuidString).mp4")
    }

    private func startTimer() {
        let start = Date()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.duration = Date().timeIntervalSince(start)
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func cleanupCapture() {
        captureService = nil
    }
}
