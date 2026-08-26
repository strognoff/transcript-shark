//
//  RecordingSession.swift
//  MeetingRecorder
//
//  Immutable value type representing one recording session.
//  Created when a session starts, passed to TranscriptionQueue on stop.
//

import Foundation

struct RecordingSession: Sendable {

    /// Unique identifier for this session.
    let id: UUID

    /// When capture began.
    let startedAt: Date

    /// When capture ended — set on stop.
    let endedAt: Date?

    /// The captured audio/video file produced by SCRecordingOutput.
    let outputURL: URL

    /// The application that triggered the recording (manual or detected).
    let meetingApplication: String

    // MARK: - Computed

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outputURL: URL,
        meetingApplication: String = "Manual"
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outputURL = outputURL
        self.meetingApplication = meetingApplication
    }

    /// Returns a copy of the session with endedAt set to now.
    func finished(at date: Date = Date()) -> RecordingSession {
        RecordingSession(
            id: id,
            startedAt: startedAt,
            endedAt: date,
            outputURL: outputURL,
            meetingApplication: meetingApplication
        )
    }
}
