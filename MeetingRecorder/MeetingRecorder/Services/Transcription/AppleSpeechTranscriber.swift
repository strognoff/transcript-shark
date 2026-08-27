//
//  AppleSpeechTranscriber.swift
//  MeetingRecorder
//
//  Concrete TranscriptionService using Apple's SFSpeechRecognizer.
//
//  SFSpeechRecognizer has a hard ~1 minute limit per recognition request.
//  For files longer than 55 seconds the audio is split into 55-second chunks,
//  each transcribed separately, then stitched back with correct timestamps.
//
//  Raw PCM .caf sidecars use SFSpeechAudioBufferRecognitionRequest — frames are
//  fed directly from AVAudioFile without touching the hardware audio queue.
//  This avoids the device-contention failure ("No speech detected") that occurs
//  when mic and system tracks are recognised concurrently via URL requests.
//
//  Compressed files (.mp4, .m4a) use SFSpeechURLRecognitionRequest via
//  AVAssetExportSession as before.
//

import Speech
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AppleSpeechTranscriber")

// Maximum duration per recognition chunk (seconds) — under the ~60s API limit
private let kChunkDuration: TimeInterval = 55

struct AppleSpeechTranscriber: TranscriptionService {

    func transcribe(audioURL: URL, language: Locale?) async throws -> TranscriptResult {
        logger.info("AppleSpeechTranscriber: starting — \(audioURL.lastPathComponent)")

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.permissionDenied
        }

        let locale = language ?? Locale.current
        guard let recogniser = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw TranscriptionError.recogniserUnavailable
        }
        recogniser.defaultTaskHint = .dictation

        let duration = try await audioDuration(url: audioURL)
        logger.info("AppleSpeechTranscriber: duration \(String(format: "%.1f", duration))s")

        if duration <= kChunkDuration {
            return try await transcribeSingle(url: audioURL, recogniser: recogniser, offset: 0, duration: duration)
        }

        logger.info("AppleSpeechTranscriber: chunking into \(Int(ceil(duration / kChunkDuration))) segments")
        return try await transcribeChunked(url: audioURL, recogniser: recogniser, totalDuration: duration)
    }

    // MARK: - Single file transcription

    private func transcribeSingle(
        url: URL,
        recogniser: SFSpeechRecognizer,
        offset: TimeInterval,
        duration: TimeInterval
    ) async throws -> TranscriptResult {
        let (text, segments): (String, [TranscriptSegment])
        if url.pathExtension.lowercased() == "caf" {
            let sr = try fileSampleRate(url: url)
            (text, segments) = try await recogniseBuffered(
                url: url, recogniser: recogniser,
                startFrame: 0,
                frameCount: AVAudioFrameCount(duration * sr),
                timeOffset: offset
            )
        } else {
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            (text, segments) = try await recogniseURL(request: request, recogniser: recogniser, timeOffset: offset)
        }
        return TranscriptResult(text: text, segments: segments, detectedLanguage: recogniser.locale.identifier, duration: duration)
    }

    // MARK: - Chunked transcription

    private func transcribeChunked(
        url: URL,
        recogniser: SFSpeechRecognizer,
        totalDuration: TimeInterval
    ) async throws -> TranscriptResult {
        var allSegments: [TranscriptSegment] = []
        var allText: [String] = []
        let isCaf = url.pathExtension.lowercased() == "caf"

        // Resolve sample rate once for buffer-based path
        let sr: Double = isCaf ? (try fileSampleRate(url: url)) : 0

        var offset: TimeInterval = 0

        while offset < totalDuration {
            let chunkDuration = min(kChunkDuration, totalDuration - offset)
            logger.info("AppleSpeechTranscriber: processing chunk at \(String(format: "%.1f", offset))s–\(String(format: "%.1f", offset + chunkDuration))s")

            do {
                let (text, segments): (String, [TranscriptSegment])

                if isCaf {
                    // Feed PCM buffers directly — no hardware audio queue involved
                    let startFrame = AVAudioFramePosition(offset * sr)
                    let frameCount = AVAudioFrameCount(chunkDuration * sr)
                    (text, segments) = try await recogniseBuffered(
                        url: url, recogniser: recogniser,
                        startFrame: startFrame,
                        frameCount: frameCount,
                        timeOffset: offset
                    )
                } else {
                    let chunkURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("chunk_\(Int(offset)).m4a")
                    defer { try? FileManager.default.removeItem(at: chunkURL) }
                    try await exportCompressedChunk(from: url, to: chunkURL, start: offset, duration: chunkDuration)
                    let request = SFSpeechURLRecognitionRequest(url: chunkURL)
                    request.shouldReportPartialResults = false
                    (text, segments) = try await recogniseURL(request: request, recogniser: recogniser, timeOffset: offset)
                }

                if !text.isEmpty {
                    allText.append(text)
                    allSegments.append(contentsOf: segments)
                    logger.info("AppleSpeechTranscriber: chunk at \(String(format: "%.1f", offset))s — \(segments.count) segments")
                } else {
                    logger.warning("AppleSpeechTranscriber: chunk at \(String(format: "%.1f", offset))s returned empty")
                }
            } catch {
                // Non-fatal: log and continue with remaining chunks
                logger.error("AppleSpeechTranscriber: chunk at \(String(format: "%.1f", offset))s failed — \(error.localizedDescription)")
            }

            offset += kChunkDuration
        }

        let fullText = allText.joined(separator: " ")
        logger.info("AppleSpeechTranscriber: completed — \(allSegments.count) total segments, \(fullText.count) chars")
        return TranscriptResult(
            text: fullText,
            segments: allSegments,
            detectedLanguage: recogniser.locale.identifier,
            duration: totalDuration
        )
    }

    // MARK: - Buffer-based recognition (CAF / raw PCM)
    //
    // Reads AVAudioPCMBuffers directly from the file and feeds them to
    // SFSpeechAudioBufferRecognitionRequest. The hardware audio queue is
    // never opened, so mic and system tracks can run concurrently without
    // device-contention errors.

    private func recogniseBuffered(
        url: URL,
        recogniser: SFSpeechRecognizer,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        timeOffset: TimeInterval
    ) async throws -> (text: String, segments: [TranscriptSegment]) {
        let sourceFile = try AVAudioFile(forReading: url)
        let format = sourceFile.processingFormat
        sourceFile.framePosition = startFrame

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false

        // Append all frames for this chunk, then signal end-of-audio
        let bufSize: AVAudioFrameCount = 8192
        var remaining = frameCount
        while remaining > 0 {
            let toRead = min(bufSize, remaining)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }
            try sourceFile.read(into: buf, frameCount: toRead)
            guard buf.frameLength > 0 else { break }
            request.append(buf)
            remaining -= buf.frameLength
        }
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recogniser.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    logger.error("AppleSpeechTranscriber: recognition error — \(error.localizedDescription)")
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                let segments = result.bestTranscription.segments.map {
                    TranscriptSegment(
                        startTime: $0.timestamp + timeOffset,
                        endTime: $0.timestamp + $0.duration + timeOffset,
                        text: $0.substring
                    )
                }
                logger.info("AppleSpeechTranscriber: final — \(text.count) chars, \(segments.count) segments")
                resumed = true
                continuation.resume(returning: (text, segments))
            }
        }
    }

    // MARK: - URL-based recognition (compressed: mp4, m4a)

    private func recogniseURL(
        request: SFSpeechURLRecognitionRequest,
        recogniser: SFSpeechRecognizer,
        timeOffset: TimeInterval
    ) async throws -> (text: String, segments: [TranscriptSegment]) {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recogniser.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    logger.error("AppleSpeechTranscriber: recognition error — \(error.localizedDescription)")
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                let segments = result.bestTranscription.segments.map {
                    TranscriptSegment(
                        startTime: $0.timestamp + timeOffset,
                        endTime: $0.timestamp + $0.duration + timeOffset,
                        text: $0.substring
                    )
                }
                logger.info("AppleSpeechTranscriber: final — \(text.count) chars, \(segments.count) segments")
                resumed = true
                continuation.resume(returning: (text, segments))
            }
        }
    }

    // MARK: - Export compressed chunk (mp4/m4a only)

    private func exportCompressedChunk(
        from url: URL,
        to destination: URL,
        start: TimeInterval,
        duration: TimeInterval
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.exportFailed
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        try await session.export(to: destination, as: .m4a)
    }

    // MARK: - Helpers

    private func audioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds
    }

    private func fileSampleRate(url: URL) throws -> Double {
        try AVAudioFile(forReading: url).processingFormat.sampleRate
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case recogniserUnavailable
    case noResult
    case exportFailed

    nonisolated var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .recogniserUnavailable:
            return "Speech recognition is not available on this device."
        case .noResult:
            return "No transcription result was produced."
        case .exportFailed:
            return "Failed to export audio chunk for transcription."
        }
    }
}
