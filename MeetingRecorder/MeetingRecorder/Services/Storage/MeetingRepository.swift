//
//  MeetingRepository.swift
//  MeetingRecorder
//
//  Scans the Recordings directory on disk and builds an in-memory list of
//  Meeting objects. Milestone 6 will replace this with SwiftData queries.
//

import Foundation
import Observation
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "MeetingRepository")

@Observable
@MainActor
final class MeetingRepository {

    private(set) var meetings: [Meeting] = []

    private let recordingsDir: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        recordingsDir = appSupport
            .appendingPathComponent("MeetingRecorder")
            .appendingPathComponent("Recordings")
    }

    // MARK: - Load

    func load() {
        Task { await reload() }
    }

    func reload() async {
        let dir = recordingsDir
        // Scan file metadata on a background thread (synchronous, no async)
        let infos: [(url: URL, createdAt: Date, transcriptURL: URL?)] = await Task.detached(priority: .userInitiated) {
            Self.scanMetadata(in: dir)
        }.value

        // Load durations on the main actor — each in its own isolated call
        var loaded: [Meeting] = []
        for info in infos {
            let duration = await Self.loadDuration(url: info.url)
            let nameUUID = info.url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "recording_", with: "")
            let id = UUID(uuidString: nameUUID) ?? UUID()
            let meeting = Meeting(
                id: id,
                title: Self.formattedTitle(from: info.createdAt),
                startedAt: info.createdAt,
                endedAt: duration > 0 ? info.createdAt.addingTimeInterval(duration) : nil,
                meetingApplication: "Manual",
                recordingURL: info.url,
                transcriptURL: info.transcriptURL,
                transcriptionStatus: info.transcriptURL != nil ? .completed : .pending
            )
            loaded.append(meeting)
        }

        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
        logger.info("MeetingRepository: loaded \(loaded.count) meetings")
    }

    private static func loadDuration(url: URL) async -> TimeInterval {
        // Create a fresh asset for each file — do NOT reuse across calls
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.isValid, !duration.isIndefinite else { return 0 }
        return duration.seconds
    }

    // MARK: - Mutations

    func delete(_ meeting: Meeting) {
        // Remove files from disk
        let dir = meeting.recordingURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: meeting.recordingURL)
        if let t = meeting.transcriptURL { try? FileManager.default.removeItem(at: t) }
        // Remove the folder if now empty
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if remaining.isEmpty { try? FileManager.default.removeItem(at: dir) }

        meetings.removeAll { $0.id == meeting.id }
        logger.info("MeetingRepository: deleted \(meeting.id)")
    }

    func retryTranscription(_ meeting: Meeting) async {
        guard let idx = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[idx].transcriptionStatus = .pending
        let session = RecordingSession(
            id: meeting.id,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            outputURL: meeting.recordingURL,
            meetingApplication: meeting.meetingApplication
        )
        await TranscriptionQueue.shared.enqueue(session)
    }

    // MARK: - Filtering

    func filtered(by filter: SidebarFilter) -> [Meeting] {
        let cal = Calendar.current
        let now = Date()
        switch filter {
        case .allMeetings:
            return meetings
        case .today:
            return meetings.filter { cal.isDateInToday($0.startedAt) }
        case .thisWeek:
            let weekAgo = cal.date(byAdding: .day, value: -7, to: now)!
            return meetings.filter { $0.startedAt >= weekAgo }
        }
    }

    func grouped(by filter: SidebarFilter) -> [MeetingDateGroup] {
        let list = filtered(by: filter)
        let cal = Calendar.current
        let now = Date()

        var groups: [(label: String, date: Date, meetings: [Meeting])] = []
        var seen: [String: Int] = [:]

        for meeting in list {
            let label: String
            if cal.isDateInToday(meeting.startedAt) {
                label = "Today"
            } else if cal.isDateInYesterday(meeting.startedAt) {
                label = "Yesterday"
            } else if meeting.startedAt >= cal.date(byAdding: .day, value: -7, to: now)! {
                let fmt = DateFormatter()
                fmt.dateFormat = "EEEE"
                label = fmt.string(from: meeting.startedAt)
            } else {
                let fmt = DateFormatter()
                fmt.dateStyle = .long
                fmt.timeStyle = .none
                label = fmt.string(from: meeting.startedAt)
            }

            if let idx = seen[label] {
                groups[idx].meetings.append(meeting)
            } else {
                seen[label] = groups.count
                groups.append((label: label, date: meeting.startedAt, meetings: [meeting]))
            }
        }

        return groups.map { MeetingDateGroup(id: $0.label, label: $0.label, meetings: $0.meetings) }
    }

    // MARK: - Disk scan (synchronous — no AVFoundation)

    private nonisolated static func scanMetadata(
        in dir: URL
    ) -> [(url: URL, createdAt: Date, transcriptURL: URL?)] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { item in
            guard item.pathExtension == "mp4" else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: item.path)
            let createdAt = attrs?[.creationDate] as? Date ?? Date()
            let transcriptURL = item.deletingLastPathComponent()
                .appendingPathComponent(item.deletingPathExtension().lastPathComponent + "_transcript.md")
            let resolvedTranscript: URL? = FileManager.default.fileExists(atPath: transcriptURL.path)
                ? transcriptURL : nil
            return (url: item, createdAt: createdAt, transcriptURL: resolvedTranscript)
        }
    }

    private static func formattedTitle(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM · HH:mm"
        return f.string(from: date)
    }
}
