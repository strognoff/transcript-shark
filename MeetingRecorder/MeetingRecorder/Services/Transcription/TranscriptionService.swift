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

struct TranscriptResult: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    let detectedLanguage: String?
    let duration: TimeInterval
}

struct TranscriptSegment: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
