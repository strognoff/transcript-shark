//
//  AppleSpeechTranscriber.swift
//  MeetingRecorder
//
//  Concrete TranscriptionService using Apple's on-device SFSpeechRecognizer.
//  All processing happens locally — no audio is sent to Apple servers when
//  requiresOnDeviceRecognition = true (requires macOS 13+).
//

import Speech
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "AppleSpeechTranscriber")

struct AppleSpeechTranscriber: TranscriptionService {

    // MARK: - TranscriptionService

    func transcribe(audioURL: URL, language: Locale?) async throws -> TranscriptResult {
        logger.info("AppleSpeechTranscriber: starting — \(audioURL.lastPathComponent)")

        // Check permission — caller must request it before invoking transcribe()
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw TranscriptionError.permissionDenied
        }

        // Resolve locale — prefer passed-in language, fall back to device locale
        let locale = language ?? Locale.current
        guard let recogniser = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw TranscriptionError.recogniserUnavailable
        }

        // Prefer on-device recognition for privacy
        recogniser.defaultTaskHint = .dictation

        // Measure audio duration for the transcript header
        let duration = try await audioDuration(url: audioURL)

        // Build the recognition request from the file URL
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        if recogniser.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            logger.info("AppleSpeechTranscriber: using on-device recognition")
        }

        // Run recognition
        var (text, segments) = try await recognise(request: request, recogniser: recogniser)

        // On-device recognition has a ~1 minute limit on some macOS versions.
        // If we get empty text and used on-device, retry without the restriction.
        if text.isEmpty && request.requiresOnDeviceRecognition {
            logger.warning("AppleSpeechTranscriber: on-device returned empty — retrying without on-device restriction")
            let fallbackRequest = SFSpeechURLRecognitionRequest(url: audioURL)
            fallbackRequest.shouldReportPartialResults = false
            (text, segments) = try await recognise(request: fallbackRequest, recogniser: recogniser)
        }

        logger.info("AppleSpeechTranscriber: completed — \(segments.count) segments, \(text.count) chars")
        return TranscriptResult(
            text: text,
            segments: segments,
            detectedLanguage: recogniser.locale.identifier,
            duration: duration
        )
    }

    // MARK: - Helpers

    // Returns (formattedString, segments) extracted on the callback thread before
    // crossing the concurrency boundary — SFSpeechRecognitionResult is not Sendable.
    private func recognise(
        request: SFSpeechURLRecognitionRequest,
        recogniser: SFSpeechRecognizer
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

                logger.info("AppleSpeechTranscriber: partial result isFinal=\(result.isFinal) text='\(result.bestTranscription.formattedString.prefix(80))'")

                guard result.isFinal else { return }

                let text = result.bestTranscription.formattedString
                let segments = result.bestTranscription.segments.map {
                    TranscriptSegment(
                        startTime: $0.timestamp,
                        endTime: $0.timestamp + $0.duration,
                        text: $0.substring
                    )
                }

                logger.info("AppleSpeechTranscriber: final — \(text.count) chars, \(segments.count) segments")
                resumed = true
                continuation.resume(returning: (text, segments))
            }
        }
    }

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

    nonisolated var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .recogniserUnavailable:
            return "Speech recognition is not available on this device."
        case .noResult:
            return "No transcription result was produced."
        }
    }
}
