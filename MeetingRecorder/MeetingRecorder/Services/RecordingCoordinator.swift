//
//  RecordingCoordinator.swift
//  MeetingRecorder
//
//  Orchestrates AudioCapture (SCStream + SCRecordingOutput) to produce
//  a finished .m4a recording. SCRecordingOutput handles all file writing
//  natively — no AVAssetWriter or manual buffer routing needed.
//

import Combine
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "RecordingCoordinator")

// MARK: - State

enum RecordingState {
    case idle
    case recording
    case finished(URL)
    case failed(Error)
}

// MARK: - Coordinator

@MainActor
final class RecordingCoordinator: ObservableObject {

    @Published var state: RecordingState = .idle
    @Published var duration: TimeInterval = 0

    private var capture: AudioCapture?
    private var timer: AnyCancellable?
    private var recordingStart: Date?

    // MARK: - Start

    func startRecording() async {
        guard case .idle = state else { return }
        logger.info("RecordingCoordinator: starting")

        do {
            let dir = try recordingsDirectory()
            let id = UUID().uuidString
            let m4aURL = dir.appendingPathComponent("recording_\(id).mp4")

            let capture = AudioCapture(outputURL: m4aURL)
            self.capture = capture

            try await capture.start()

            state = .recording
            recordingStart = Date()
            startTimer()
            logger.info("RecordingCoordinator: recording started")

        } catch {
            logger.error("RecordingCoordinator: start failed — \(error.localizedDescription)")
            state = .failed(error)
            cleanup()
        }
    }

    // MARK: - Stop

    func stopRecording() async {
        guard case .recording = state else { return }
        logger.info("RecordingCoordinator: stopping")
        stopTimer()

        do {
            guard let capture else { throw RecordingCoordinatorError.missingCapture }
            let outputURL = capture.outputURL

            try await capture.stop()

            state = .finished(outputURL)
            logger.info("RecordingCoordinator: finished — \(outputURL.lastPathComponent)")

        } catch {
            logger.error("RecordingCoordinator: stop failed — \(error.localizedDescription)")
            state = .failed(error)
        }

        cleanup()
    }

    // MARK: - Reset

    func reset() {
        cleanup()
        duration = 0
        state = .idle
    }

    // MARK: - Helpers

    private func recordingsDirectory() throws -> URL {
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
        return dir
    }

    private func startTimer() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let start = self.recordingStart else { return }
                self.duration = Date().timeIntervalSince(start)
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func cleanup() {
        capture = nil
        recordingStart = nil
    }
}

// MARK: - Errors

enum RecordingCoordinatorError: LocalizedError {
    case missingCapture

    var errorDescription: String? {
        "No active recording session found."
    }
}
