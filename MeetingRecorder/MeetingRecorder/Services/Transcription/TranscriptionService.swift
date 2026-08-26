//
//  TranscriptionService.swift
//  MeetingRecorder
//
//  Protocol + result types for transcription.
//  UI code and the queue reference only this protocol — never AppleSpeechTranscriber.
//

import Foundation

// MARK: - Protocol

protocol TranscriptionService: Sendable {
    func transcribe(audioURL: URL, language: Locale?) async throws -> TranscriptResult
}

// MARK: - Result types

nonisolated struct TranscriptResult: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    let detectedLanguage: String?
    let duration: TimeInterval
}

nonisolated struct TranscriptSegment: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: Speaker

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: Speaker = .unknown) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}

/// Identifies who spoke a given segment.
enum Speaker: Sendable {
    /// The local user (microphone input).
    case me
    /// Remote participant(s) (system audio).
    case them
    /// Source could not be determined (e.g. combined audio).
    case unknown
}

nonisolated extension Speaker: Equatable {}
