//
//  MeetingRecord.swift
//  MeetingRecorder
//
//  SwiftData persistent model for a meeting.
//  URL values are stored as String (SwiftData does not natively support URL).
//  The Meeting struct (view layer) is produced from this model via .toMeeting().
//

import Foundation
import SwiftData

@Model
final class MeetingRecord {

    // MARK: - Identity
    @Attribute(.unique) var id: UUID
    var title: String
    var meetingApplication: String

    // MARK: - Timing
    var startedAt: Date
    var endedAt: Date?

    // MARK: - File paths (stored as strings, converted to URL on access)
    var recordingPath: String       // relative to ~/Library/Application Support/MeetingRecorder/
    var transcriptPath: String?

    // MARK: - Transcription
    var transcriptionStatusRaw: String  // "pending" | "processing" | "completed" | "failed:<msg>"

    // MARK: - AI Summary
    var summaryPromptOverride: String?

    // MARK: - Folder (Milestone 7)
    var folderID: UUID?

    // MARK: - Timestamps
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        meetingApplication: String = "Manual",
        startedAt: Date,
        endedAt: Date? = nil,
        recordingPath: String,
        transcriptPath: String? = nil,
        transcriptionStatusRaw: String = "pending",
        summaryPromptOverride: String? = nil,
        folderID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.meetingApplication = meetingApplication
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordingPath = recordingPath
        self.transcriptPath = transcriptPath
        self.transcriptionStatusRaw = transcriptionStatusRaw
        self.summaryPromptOverride = summaryPromptOverride
        self.folderID = folderID
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Convert to view-layer Meeting struct

    func toMeeting(baseURL: URL) -> Meeting {
        let recordingURL = baseURL.appendingPathComponent(recordingPath)
        let transcriptURL = transcriptPath.map { baseURL.appendingPathComponent($0) }

        return Meeting(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            meetingApplication: meetingApplication,
            recordingURL: recordingURL,
            transcriptURL: transcriptURL,
            transcriptionStatus: TranscriptionStatus(rawString: transcriptionStatusRaw),
            folderID: folderID,
            summaryPromptOverride: summaryPromptOverride
        )
    }

    // MARK: - Update from Meeting struct

    func update(from meeting: Meeting, baseURL: URL) {
        title = meeting.title
        endedAt = meeting.endedAt
        transcriptPath = meeting.transcriptURL.map {
            $0.path.replacingOccurrences(of: baseURL.path + "/", with: "")
        }
        transcriptionStatusRaw = meeting.transcriptionStatus.rawString
        summaryPromptOverride = meeting.summaryPromptOverride
        updatedAt = Date()
    }
}

// MARK: - TranscriptionStatus ↔ String

extension TranscriptionStatus {
    nonisolated init(rawString: String) {
        switch rawString {
        case "pending":    self = .pending
        case "processing": self = .processing
        case "completed":  self = .completed
        default:
            if rawString.hasPrefix("failed:") {
                self = .failed(String(rawString.dropFirst(7)))
            } else {
                self = .pending
            }
        }
    }

    nonisolated var rawString: String {
        switch self {
        case .pending:         return "pending"
        case .processing:      return "processing"
        case .completed:       return "completed"
        case .failed(let msg): return "failed:\(msg)"
        }
    }
}
