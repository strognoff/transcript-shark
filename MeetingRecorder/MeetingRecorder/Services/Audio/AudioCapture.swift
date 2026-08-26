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

        // Capture from the meeting app's virtual audio device if present.
        // Teams routes call audio through "MSLoopbackDriverDevice_UID" which is
        // NOT included in the default system audio mix captured by SCStream.
        if let meetingDeviceID = Self.findMeetingAudioDeviceID() {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = meetingDeviceID
            logger.info("AudioCapture: capturing virtual meeting audio device — \(meetingDeviceID)")
        }

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
            // Register a microphone stub when captureMicrophone is enabled —
            // SCStream requires a handler for every output type it produces.
            if config.captureMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue.main)
            }
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

// MARK: - Meeting audio device discovery

extension AudioCapture {

    /// Known virtual audio device UIDs created by meeting applications.
    private static let knownMeetingDeviceUIDs: [String] = [
        "MSLoopbackDriverDevice_UID",   // Microsoft Teams
        "zoom.us.zoomaudiodevice.001",  // Zoom
        "com.webex.meeting.audiodevice", // Webex
    ]

    /// Known meeting audio device names (fallback if UID doesn't match).
    private static let knownMeetingDeviceNames: [String] = [
        "Microsoft Teams Audio",
        "ZoomAudioDevice",
        "Webex Audio",
    ]

    /// Returns the UID of the first known meeting app virtual audio device found,
    /// or nil if none is active. Uses CoreAudio to enumerate devices.
    static func findMeetingAudioDeviceID() -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            if let uid = audioDeviceUID(deviceID),
               knownMeetingDeviceUIDs.contains(uid) {
                return uid
            }
            if let name = audioDeviceName(deviceID),
               knownMeetingDeviceNames.contains(where: { name.contains($0) }) {
                return audioDeviceUID(deviceID)
            }
        }
        return nil
    }

    private static func audioDeviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID) == noErr else { return nil }
        return cfUID as String
    }

    private static func audioDeviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName) == noErr else { return nil }
        return cfName as String
    }
}

// MARK: - SCStreamOutput (stub)

extension AudioCapture: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        // SCRecordingOutput handles all writing.
        // This stub satisfies SCStream's requirement that every enabled output
        // type (.audio, .screen, .microphone) has a registered handler.
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
