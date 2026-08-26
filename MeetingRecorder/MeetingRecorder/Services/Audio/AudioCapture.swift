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
import CoreAudio
import OSLog

@MainActor
final class AudioCapture: NSObject, AudioCaptureService {

    private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")

    let outputURL: URL
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var isStopping = false   // guard against double-stop

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
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5) // 5fps

        // Note: microphoneCaptureDeviceID requires an INPUT device (microphone),
        // not a loopback output device like Teams Audio. Teams call audio is
        // captured via capturesAudio = true when Teams routes through the system
        // audio graph. We do NOT set captureMicrophone to avoid stream corruption.

        logger.info("AudioCapture: configuring recording output → \(self.outputURL.lastPathComponent)")

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL      = outputURL
        recordingConfig.outputFileType = AVFileType(rawValue: "public.mpeg-4")

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
        isStopping = false

        logger.info("AudioCapture: starting capture")
        try await stream.startCapture()
        logger.info("AudioCapture: capture started ✓")
    }

    // MARK: - Stop

    func stop() async throws {
        guard !isStopping else {
            logger.warning("AudioCapture: stop() called while already stopping — ignored")
            return
        }
        guard let stream else {
            logger.warning("AudioCapture: stop() called with no active stream — ignored")
            return
        }

        isStopping = true
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
        // SCRecordingOutput handles all writing.
        // This stub satisfies SCStream's requirement that every enabled output
        // type (.audio, .screen) has a registered handler.
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

// MARK: - Meeting audio device discovery (for future use)

extension AudioCapture {
    /// Returns the UID of a known meeting app virtual audio device if present.
    /// NOTE: These are OUTPUT/loopback devices — they cannot be used with
    /// SCStreamConfiguration.microphoneCaptureDeviceID which requires INPUT devices.
    /// Kept here for future use with AVAudioEngine tap-based capture.
    static func findMeetingAudioDeviceID() -> String? {
        let knownUIDs = ["MSLoopbackDriverDevice_UID", "zoom.us.zoomaudiodevice.001"]
        let knownNames = ["Microsoft Teams Audio", "ZoomAudioDevice", "Webex Audio"]

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids {
            if let uid = deviceUID(id), knownUIDs.contains(uid) { return uid }
            if let name = deviceName(id), knownNames.contains(where: { name.contains($0) }) { return deviceUID(id) }
        }
        return nil
    }

    private static func deviceUID(_ id: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == noErr ? (s as String) : nil
    }

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == noErr ? (s as String) : nil
    }
}
