//
//  AppleSpeechTranscriber.swift
//  MeetingRecorder
//
//  Concrete TranscriptionService using Apple's SFSpeechRecognizer.
//
//  SFSpeechRecognizer has a hard ~1 minute limit per recognition request.
//  For files longer than 55 seconds, the audio is split into overlapping
//  55-second chunks using AVAssetExportSession, each chunk transcribed
//  separately, then results are stitched back together with correct timestamps.
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

        // For short files, transcribe directly
        if duration <= kChunkDuration {
            return try await transcribeSingle(url: audioURL, recogniser: recogniser, offset: 0, duration: duration)
        }

        // For long files, chunk into 55s segments
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
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Don't force on-device — it cuts off at ~1min even for short files on some macOS versions
        // request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition

        let (text, segments) = try await recognise(request: request, recogniser: recogniser, timeOffset: offset)
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

        var offset: TimeInterval = 0
        let tempDir = FileManager.default.temporaryDirectory

        while offset < totalDuration {
            let chunkDuration = min(kChunkDuration, totalDuration - offset)
            let chunkURL = tempDir.appendingPathComponent("chunk_\(Int(offset)).m4a")

            logger.info("AppleSpeechTranscriber: exporting chunk at \(String(format: "%.1f", offset))s–\(String(format: "%.1f", offset + chunkDuration))s")

            try await exportChunk(from: url, to: chunkURL, start: offset, duration: chunkDuration)

            let request = SFSpeechURLRecognitionRequest(url: chunkURL)
            request.shouldReportPartialResults = false

            let (text, segments) = try await recognise(request: request, recogniser: recogniser, timeOffset: offset)

            if !text.isEmpty {
                allText.append(text)
                allSegments.append(contentsOf: segments)
                logger.info("AppleSpeechTranscriber: chunk at \(String(format: "%.1f", offset))s — \(segments.count) segments")
            } else {
                logger.warning("AppleSpeechTranscriber: chunk at \(String(format: "%.1f", offset))s returned empty")
            }

            // Clean up chunk file
            try? FileManager.default.removeItem(at: chunkURL)

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

    // MARK: - Export a time range to a new file

    private func exportChunk(from url: URL, to destination: URL, start: TimeInterval, duration: TimeInterval) async throws {
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

    // MARK: - Core recognition

    private func recognise(
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

                guard let result else { return }
                guard result.isFinal else { return }

                let text = result.bestTranscription.formattedString
                // Shift segment timestamps by the chunk offset
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

    // MARK: - Helpers

    private func audioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds
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
