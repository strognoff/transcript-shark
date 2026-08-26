//
//  AudioCapture.swift
//  MeetingRecorder
//
//  Records system audio using SCStream + SCRecordingOutput (macOS 15+).
//  Must be called from @MainActor context.
//

import ScreenCaptureKit
import AVFoundation
import CoreMedia
import OSLog

@MainActor
final class AudioCapture: NSObject, AudioCaptureService {

    private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")

    let outputURL: URL
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    // MARK: - Start

    func start() async throws {
        logger.info("AudioCapture: requesting screen content")

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        logger.info("AudioCapture: got \(content.displays.count) display(s)")

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate    = 48000
        config.channelCount  = 2
        config.width  = 1280
        config.height = 720
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)

        logger.info("AudioCapture: configuring recording output → \(self.outputURL.lastPathComponent)")

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL      = outputURL
        recordingConfig.outputFileType = AVFileType(rawValue: "public.mpeg-4")

        logger.info("AudioCapture: available file types: \(recordingConfig.availableOutputFileTypes.map(\.rawValue))")

        let recOut = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        self.recordingOutput = recOut

        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        do {
            try stream.addRecordingOutput(recOut)
            logger.info("AudioCapture: recording output added")
            try stream.addStreamOutput(self, type: .audio,  sampleHandlerQueue: DispatchQueue.main)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.main)
            logger.info("AudioCapture: stream outputs added")
        } catch {
            logger.error("AudioCapture: failed to configure stream — \(error.localizedDescription)")
            throw error
        }

        self.stream = stream

        logger.info("AudioCapture: starting capture")
        try await stream.startCapture()
        logger.info("AudioCapture: capture started ✓")
    }

    // MARK: - Stop

    func stop() async throws {
        guard let stream else { return }
        logger.info("AudioCapture: stopping")
        try await stream.stopCapture()
        self.stream = nil
        self.recordingOutput = nil
        logger.info("AudioCapture: stopped")
    }
}

// MARK: - SCStreamOutput (stub)

extension AudioCapture: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        // SCRecordingOutput handles all writing
    }
}

// MARK: - SCStreamDelegate

extension AudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        logger.error("AudioCapture: stream stopped with error — \(error.localizedDescription)")
    }
}

// MARK: - SCRecordingOutputDelegate

extension AudioCapture: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        logger.info("AudioCapture: ✓ SCRecordingOutput started")
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        logger.error("AudioCapture: ✗ SCRecordingOutput failed — \(error.localizedDescription)")
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        logger.info("AudioCapture: SCRecordingOutput finished — \(recordingOutput.recordedFileSize) bytes")
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDisplayFound
    nonisolated var errorDescription: String? { "No display found for audio capture." }
}
