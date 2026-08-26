//
//  AudioCapture.swift
//  MeetingRecorder
//
//  Records audio using two parallel streams:
//  1. SCStream + SCRecordingOutput → MP4 (system audio + video container)
//  2. AVAudioEngine tap on Teams/Zoom virtual device → CAF sidecar
//
//  On stop, the sidecar audio is merged into the MP4 via AVMutableComposition
//  so the final file contains both system audio and meeting call audio.
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
    private var audioEngine: AVAudioEngine?
    private var sidecarURL: URL?
    private var sidecarFile: AVAudioFile?
    private var isStopping = false

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    // MARK: - Start

    func start() async throws {
        logger.info("AudioCapture: requesting screen content")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        logger.info("AudioCapture: got \(content.displays.count) display(s)")
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplayFound }

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

        let recOut = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        self.recordingOutput = recOut
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        do {
            try stream.addRecordingOutput(recOut)
            try stream.addStreamOutput(self, type: .audio,  sampleHandlerQueue: DispatchQueue.main)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.main)
            logger.info("AudioCapture: stream outputs added")
        } catch {
            logger.error("AudioCapture: failed to configure stream — \(error.localizedDescription)")
            throw error
        }

        self.stream = stream
        isStopping = false

        // Start AVAudioEngine tap on Teams/Zoom virtual device (if present)
        startMeetingAudioTap()

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

        // Stop engine tap first
        stopMeetingAudioTap()

        // Stop SCStream — SCRecordingOutput will finish writing the MP4
        do { try await stream.stopCapture() } catch {
            logger.warning("AudioCapture: stop error (non-fatal) — \(error.localizedDescription)")
        }
        self.stream = nil

        // Merge sidecar audio into the MP4 if it has meaningful content (> 4KB)
        if let sidecar = sidecarURL {
            let sidecarSize = (try? FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? Int) ?? 0
            if sidecarSize > 4096 {
                logger.info("AudioCapture: sidecar size \(sidecarSize) bytes — merging")
                await mergeSidecar(sidecar, into: outputURL)
            } else {
                logger.warning("AudioCapture: sidecar too small (\(sidecarSize) bytes) — skipping merge")
            }
            try? FileManager.default.removeItem(at: sidecar)
            self.sidecarURL = nil
        }

        self.recordingOutput = nil
        logger.info("AudioCapture: stopped")
    }

    // MARK: - Meeting audio tap (AVAudioEngine on virtual device)

    private func startMeetingAudioTap() {
        guard let deviceUID = AudioCapture.findMeetingAudioDeviceID() else {
            logger.info("AudioCapture: no meeting virtual audio device found — system audio only")
            return
        }

        do {
            let engine = AVAudioEngine()

            // Resolve UID → numeric AudioDeviceID, then set on the engine's input node
            guard let numericID = Self.audioDeviceID(forUID: deviceUID) else {
                logger.warning("AudioCapture: could not resolve device ID for UID \(deviceUID) — skipping tap")
                return
            }
            let unit = engine.inputNode.audioUnit!
            var deviceID = numericID
            let err = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard err == noErr else {
                logger.warning("AudioCapture: failed to set meeting audio device (\(err)) — skipping tap")
                return
            }

            // Use the hardware format to avoid format mismatch — do NOT use
            // outputFormat(forBus:) which returns the engine's internal client format
            let hwFormat = engine.inputNode.inputFormat(forBus: 0)
            let tapFormat = hwFormat.sampleRate > 0 ? hwFormat : engine.inputNode.outputFormat(forBus: 0)

            logger.info("AudioCapture: tap format — \(tapFormat.sampleRate)Hz \(tapFormat.channelCount)ch")

            let sidecar = outputURL.deletingLastPathComponent()
                .appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + "_meeting_audio.caf")
            sidecarURL = sidecar

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: tapFormat.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let audioFile = try AVAudioFile(forWriting: sidecar, settings: settings)
            self.sidecarFile = audioFile

            // AVAudioFile.write is thread-safe. Capture the file directly into
            // the closure to avoid crossing the @MainActor boundary from the tap thread.
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                try? audioFile.write(from: buffer)
            }

            try engine.start()
            self.audioEngine = engine
            logger.info("AudioCapture: meeting audio tap started on \(deviceUID)")
        } catch {
            logger.warning("AudioCapture: could not start meeting audio tap — \(error.localizedDescription)")
            audioEngine = nil
            sidecarFile = nil
            sidecarURL = nil
        }
    }

    private func stopMeetingAudioTap() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sidecarFile = nil
        audioEngine = nil
        logger.info("AudioCapture: meeting audio tap stopped")
    }

    // MARK: - Merge sidecar into MP4

    private func mergeSidecar(_ sidecarURL: URL, into mp4URL: URL) async {
        guard FileManager.default.fileExists(atPath: sidecarURL.path),
              FileManager.default.fileExists(atPath: mp4URL.path) else { return }

        logger.info("AudioCapture: merging meeting audio sidecar into MP4")

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: mp4URL)
        let audioAsset = AVURLAsset(url: sidecarURL)

        do {
            // Copy video + existing audio tracks from MP4
            let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            let existingAudioTracks = try await videoAsset.loadTracks(withMediaType: .audio)
            let videoDuration = try await videoAsset.load(.duration)

            if let videoTrack = videoTracks.first {
                let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compVideo?.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
            }
            if let audioTrack = existingAudioTracks.first {
                let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compAudio?.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: audioTrack, at: .zero)
            }

            // Add the meeting audio sidecar as a second audio track
            let sidecarTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            let sidecarDuration = try await audioAsset.load(.duration)
            if let sidecarTrack = sidecarTracks.first {
                let compMeeting = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                let range = CMTimeRange(start: .zero, duration: min(videoDuration, sidecarDuration))
                try compMeeting?.insertTimeRange(range, of: sidecarTrack, at: .zero)
            }

            // Export merged composition back to the same URL
            let tempURL = mp4URL.deletingLastPathComponent()
                .appendingPathComponent(mp4URL.deletingPathExtension().lastPathComponent + "_merged.mp4")

            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                logger.error("AudioCapture: could not create export session for merge")
                return
            }
            session.outputURL = tempURL
            session.outputFileType = .mp4

            try await session.export(to: tempURL, as: .mp4)

            // Replace original with merged file
            try FileManager.default.removeItem(at: mp4URL)
            try FileManager.default.moveItem(at: tempURL, to: mp4URL)
            logger.info("AudioCapture: merge complete — \(mp4URL.lastPathComponent)")

        } catch {
            logger.error("AudioCapture: merge failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Meeting audio device discovery

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

    /// Converts a device UID string to a numeric AudioDeviceID.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            &cfUID,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
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

// MARK: - SCStreamOutput (stub)

extension AudioCapture: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        // SCRecordingOutput handles all writing
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
    nonisolated var errorDescription: String? { "No display found for audio capture." }
}
