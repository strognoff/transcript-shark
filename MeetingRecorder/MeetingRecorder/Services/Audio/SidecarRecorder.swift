//
//  SidecarRecorder.swift
//  MeetingRecorder
//
//  Writes raw CMSampleBuffers from SCStreamOutput into separate .caf files —
//  one for system audio (remote participants) and one for microphone (me).
//  These sidecars enable speaker-labelled transcription.
//
//  Usage:
//    let recorder = SidecarRecorder(baseURL: outputURL)
//    recorder.appendSystem(buffer)    ← called from .audio SCStreamOutput
//    recorder.appendMicrophone(buffer) ← called from .microphone SCStreamOutput
//    try await recorder.finish()
//

import AVFoundation
import CoreMedia
import OSLog

final class SidecarRecorder: Sendable {

    private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "SidecarRecorder")

    // URLs for the two sidecar files
    let systemURL: URL
    let micURL: URL

    // Writers — protected by their own internal lock via nonisolated(unsafe)
    private nonisolated(unsafe) var systemFile: AVAudioFile?
    private nonisolated(unsafe) var micFile: AVAudioFile?
    private nonisolated(unsafe) var isStarted = false
    private let lock = NSLock()

    init(outputURL: URL) {
        let base = outputURL.deletingPathExtension().lastPathComponent
        let dir  = outputURL.deletingLastPathComponent()
        systemURL = dir.appendingPathComponent("\(base)_system.caf")
        micURL    = dir.appendingPathComponent("\(base)_mic.caf")
    }

    // MARK: - Append (called from SCStreamOutput — background thread)

    nonisolated func appendSystem(_ buffer: CMSampleBuffer) {
        lock.withLock {
            if systemFile == nil {
                systemFile = makeFile(url: systemURL, buffer: buffer)
                isStarted = true
            }
            guard let file = systemFile,
                  let pcm = buffer.toPCMBuffer() else { return }
            try? file.write(from: pcm)
        }
    }

    nonisolated func appendMicrophone(_ buffer: CMSampleBuffer) {
        lock.withLock {
            if micFile == nil {
                micFile = makeFile(url: micURL, buffer: buffer)
            }
            guard let file = micFile,
                  let pcm = buffer.toPCMBuffer() else { return }
            try? file.write(from: pcm)
        }
    }

    // MARK: - Finish

    func finish() {
        lock.withLock {
            systemFile = nil   // flushes and closes
            micFile    = nil
        }
        let sysSize = fileSize(systemURL)
        let micSize = fileSize(micURL)
        logger.info("SidecarRecorder: finished — system \(sysSize) bytes, mic \(micSize) bytes")
    }

    // MARK: - Helpers

    var hasMeaningfulContent: Bool {
        fileSize(systemURL) > 8192 || fileSize(micURL) > 8192
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private nonisolated func makeFile(url: URL, buffer: CMSampleBuffer) -> AVAudioFile? {
        guard let desc = buffer.formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return nil }
        var asbd2 = asbd
        let format = AVAudioFormat(streamDescription: &asbd2)
        let settings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVSampleRateKey:           asbd.mSampleRate,
            AVNumberOfChannelsKey:     asbd.mChannelsPerFrame,
            AVLinearPCMBitDepthKey:    32,
            AVLinearPCMIsFloatKey:     true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try? AVAudioFile(forWriting: url, settings: settings)
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    nonisolated func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return nil }
        var asbd2 = asbd
        guard let format = AVAudioFormat(streamDescription: &asbd2) else { return nil }
        let frameCount = AVAudioFrameCount(numSamples)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
