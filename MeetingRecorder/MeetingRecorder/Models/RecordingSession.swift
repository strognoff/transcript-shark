//
//  RecordingSession.swift
//  MeetingRecorder
//
//  Immutable Sendable value type representing one recording session.
//  Explicitly nonisolated throughout so it can be used from any actor context.
//

import Foundation

struct RecordingSession: Sendable {

    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let outputURL: URL
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
