//
//  Meeting.swift
//  MeetingRecorder
//
//  In-memory meeting model for Milestone 5.
//  SwiftData persistence is added in Milestone 6.
//

import Foundation

// MARK: - Meeting

struct Meeting: Identifiable, Sendable, Hashable {

    static func == (lhs: Meeting, rhs: Meeting) -> Bool {
        lhs.id == rhs.id &&
        lhs.transcriptionStatus == rhs.transcriptionStatus &&
        lhs.transcriptURL == rhs.transcriptURL &&
        lhs.title == rhs.title &&
        lhs.summaryPromptOverride == rhs.summaryPromptOverride
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    var title: String
    let startedAt: Date
    let endedAt: Date?
    let meetingApplication: String
    let recordingURL: URL
    var transcriptURL: URL?
    var transcriptionStatus: TranscriptionStatus
    var folderID: UUID?
    var summaryPromptOverride: String?

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

// MARK: - Sidebar filter

enum SidebarFilter: Hashable {
    case allMeetings
    case today
    case thisWeek
    case folder(UUID)
}

// MARK: - Date grouping

struct MeetingDateGroup: Identifiable {
    let id: String   // the group label
    let label: String
    let meetings: [Meeting]
}
