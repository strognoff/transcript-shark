//
//  AudioCapture.swift
//  MeetingRecorder
//
//  Records system audio using SCStream + SCRecordingOutput (macOS 15+).
//  Must be called from @MainActor context.
//
//  Note on Teams audio: Teams routes call audio through a private virtual
//  device (MSLoopbackDriverDevice_UID) that cannot be tapped by sandboxed
//  apps without a system extension. This is a known macOS limitation.
//  Phase 2 will explore system extension or Whisper-based approaches.
//  For now, SCStream captures whatever goes through the system audio mix.
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
    private let captureScope: RecordingCaptureScope
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var isStopping = false
    // Accessed from nonisolated SCStreamOutput callback — SidecarRecorder is internally thread-safe
    nonisolated(unsafe) private(set) var sidecarRecorder: SidecarRecorder?

    // Dedicated queue for sidecar audio writes — keeps main thread free and prevents
    // buffer drops at high sample rates (48 kHz delivers hundreds of callbacks/second).
    private let sidecarQueue = DispatchQueue(
        label: "com.transcript-shark.MeetingRecorder.sidecarAudio",
        qos: .userInitiated
    )

    init(outputURL: URL, captureScope: RecordingCaptureScope = .wholeScreen) {
        self.outputURL = outputURL
        self.captureScope = captureScope
        super.init()
    }

    // MARK: - Start

    func start() async throws {
        logger.info("AudioCapture: requesting screen content")
        let content: SCShareableContent
        do {
            content = try await ScreenCaptureWindowProvider.shareableContent(onScreenWindowsOnly: false)
        } catch {
            if Self.isScreenCapturePermissionError(error) {
                logger.error("AudioCapture: permission denied — \(error.localizedDescription)")
                throw AudioCaptureError.permissionDenied
            }
            throw error
        }
        logger.info("AudioCapture: got \(content.displays.count) display(s)")

        let target = try captureTarget(from: content)
        let filter = target.filter
        let config = SCStreamConfiguration()
        config.capturesAudio    = true   // system audio (Teams, other apps)
        config.captureMicrophone = true  // default microphone (me)
        // No microphoneCaptureDeviceID — uses system default microphone
        config.sampleRate    = 48000
        config.channelCount  = 2
        config.width  = target.width
        config.height = target.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)

        logger.info("🎙 Microphone capture enabled (system default device)")
        logger.info("AudioCapture: configuring recording output → \(self.outputURL.lastPathComponent)")
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL      = outputURL
        recordingConfig.outputFileType = AVFileType(rawValue: "public.mpeg-4")

        let recOut = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        self.recordingOutput = recOut
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        do {
            try stream.addRecordingOutput(recOut)
            try stream.addStreamOutput(self, type: .audio,      sampleHandlerQueue: sidecarQueue)
            try stream.addStreamOutput(self, type: .screen,     sampleHandlerQueue: DispatchQueue.main)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sidecarQueue)
            logger.info("AudioCapture: stream outputs added (system audio + microphone)")
        } catch {
            logger.error("AudioCapture: failed to configure stream — \(error.localizedDescription)")
            throw error
        }

        self.stream = stream
        self.sidecarRecorder = SidecarRecorder(outputURL: outputURL)
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

        do { try await stream.stopCapture() } catch {
            logger.warning("AudioCapture: stop error (non-fatal) — \(error.localizedDescription)")
        }
        sidecarRecorder?.finish()
        self.stream = nil
        self.recordingOutput = nil
        self.sidecarRecorder = nil
        logger.info("AudioCapture: stopped")
    }

    // MARK: - Capture target

    private struct CaptureTarget {
        let filter: SCContentFilter
        let width: Int
        let height: Int
    }

    private func captureTarget(from content: SCShareableContent) throws -> CaptureTarget {
        switch captureScope {
        case .wholeScreen:
            return try wholeScreenTarget(from: content)

        case .selectedWindow(let windowID, let fallbackToWholeScreen):
            if let window = ScreenCaptureWindowProvider.window(matching: windowID, in: content) {
                let frame = window.frame
                logger.info("AudioCapture: using selected-window capture")
                return CaptureTarget(
                    filter: SCContentFilter(desktopIndependentWindow: window),
                    width: max(2, Int(frame.width.rounded(.up))),
                    height: max(2, Int(frame.height.rounded(.up)))
                )
            }

            guard fallbackToWholeScreen else { throw AudioCaptureError.selectedWindowUnavailable }
            logger.warning("AudioCapture: selected window unavailable — falling back to whole-screen capture")
            return try wholeScreenTarget(from: content)
        }
    }

    private func wholeScreenTarget(from content: SCShareableContent) throws -> CaptureTarget {
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplayFound }
        return CaptureTarget(
            filter: SCContentFilter(display: display, excludingWindows: []),
            width: 1280,
            height: 720
        )
    }

    nonisolated static func isScreenCapturePermissionError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("permission")
            || message.contains("denied")
            || message.contains("declined")
            || message.contains("tcc")
            || message.contains("not authorized")
            || (error as NSError).code == 7 /* SCStreamErrorCode.userDeclined */
    }

    // MARK: - Meeting audio device info (Phase 2)

    /// Returns the UID of a known meeting app virtual audio device if present.
    /// These are output/loopback devices — direct tap requires a system extension.
    static func findMeetingAudioDeviceID() -> String? {
        let knownUIDs  = ["MSLoopbackDriverDevice_UID", "zoom.us.zoomaudiodevice.001"]
        let knownNames = ["Microsoft Teams Audio", "ZoomAudioDevice", "Webex Audio"]
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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

// MARK: - SCStreamOutput

extension AudioCapture: SCStreamOutput {

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // SCRecordingOutput handles all writing.
        // We log the first buffer from each source to confirm both are active.
        switch outputType {
        case .audio:
            AudioCapture.logOnce(key: "systemAudio") {
                let l = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
                l.info("🔊 System audio: first sample received")
            }
            sidecarRecorder?.appendSystem(sampleBuffer)

        case .microphone:
            AudioCapture.logOnce(key: "microphone") {
                let l = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
                l.info("🎙 Microphone: first sample received")
            }
            sidecarRecorder?.appendMicrophone(sampleBuffer)

        default:
            break
        }
    }

    // Log-once helper — thread-safe via NSLock, accessed from nonisolated context
    private nonisolated(unsafe) static var loggedKeys = Set<String>()
    private nonisolated(unsafe) static let logLock = NSLock()

    private nonisolated static func logOnce(key: String, _ body: () -> Void) {
        logLock.lock()
        defer { logLock.unlock() }
        guard !loggedKeys.contains(key) else { return }
        loggedKeys.insert(key)
        body()
    }
}

// MARK: - SCStreamDelegate

extension AudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let l = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        l.error("AudioCapture: stream stopped with error — \(error.localizedDescription)")
    }
}

// MARK: - SCRecordingOutputDelegate

extension AudioCapture: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let l = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        l.info("AudioCapture: ✓ SCRecordingOutput started")
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let l = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        l.error("AudioCapture: ✗ SCRecordingOutput failed — \(error.localizedDescription)")
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let l = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AudioCapture")
        l.info("AudioCapture: SCRecordingOutput finished — \(recordingOutput.recordedFileSize) bytes")
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDisplayFound
    case permissionDenied
    case selectedWindowUnavailable

    nonisolated var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture."
        case .permissionDenied:
            return "Screen Recording permission is required to capture audio. Please grant access in System Settings > Privacy & Security > Screen Recording."
        case .selectedWindowUnavailable:
            return "The selected capture window is no longer available."
        }
    }
}
