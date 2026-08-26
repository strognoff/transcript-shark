//
//  MeetingRepository.swift
//  MeetingRecorder
//
//  SwiftData-backed repository for meetings.
//  On first launch, imports existing .mp4 files from the Recordings directory.
//

import Foundation
import SwiftData
import AVFoundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "MeetingRepository")

@Observable
@MainActor
final class MeetingRepository {

    private(set) var meetings: [Meeting] = []

    private let context: ModelContext
    private let baseURL: URL

    init(context: ModelContext = PersistenceController.shared.container.mainContext) {
        self.context = context
        self.baseURL = PersistenceController.baseURL
    }

    // MARK: - Load

    func load() {
        Task { await reload() }
    }

    func reload() async {
        // Import any new recordings from disk not yet in the database
        await importNewRecordingsFromDisk()

        // Fetch all records, sorted newest-first
        let descriptor = FetchDescriptor<MeetingRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        do {
            let records = try context.fetch(descriptor)
            meetings = records.map { $0.toMeeting(baseURL: baseURL) }
            logger.info("MeetingRepository: loaded \(records.count) meetings")
        } catch {
            logger.error("MeetingRepository: fetch failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Import from disk (migration / first-launch)

    private func importNewRecordingsFromDisk() async {
        let recordingsDir = baseURL.appendingPathComponent("Recordings")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let mp4Files = files.filter { $0.pathExtension == "mp4" }

        for file in mp4Files {
            let nameUUID = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "recording_", with: "")
            guard let id = UUID(uuidString: nameUUID) else { continue }

            // Skip if already in database
            let existing = try? context.fetch(
                FetchDescriptor<MeetingRecord>(
                    predicate: #Predicate { $0.id == id }
                )
            )
            if (existing?.isEmpty == false) { continue }

            // Load duration
            let duration = await Self.loadDuration(url: file)
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let createdAt = attrs?[.creationDate] as? Date ?? Date()

            // Check for transcript
            let transcriptFile = file.deletingLastPathComponent()
                .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "_transcript.md")
            let hasTranscript = FileManager.default.fileExists(atPath: transcriptFile.path)

            // Store path relative to baseURL
            let relativeRecording = file.path.replacingOccurrences(of: baseURL.path + "/", with: "")
            let relativeTranscript = hasTranscript
                ? transcriptFile.path.replacingOccurrences(of: baseURL.path + "/", with: "")
                : nil

            let record = MeetingRecord(
                id: id,
                title: Self.formattedTitle(from: createdAt),
                startedAt: createdAt,
                endedAt: duration > 0 ? createdAt.addingTimeInterval(duration) : nil,
                recordingPath: relativeRecording,
                transcriptPath: relativeTranscript,
                transcriptionStatusRaw: hasTranscript ? "completed" : "pending"
            )
            context.insert(record)
            logger.info("MeetingRepository: imported \(file.lastPathComponent)")
        }

        try? context.save()
    }

    // MARK: - Mutations

    func delete(_ meeting: Meeting) {
        // Remove files from disk
        try? FileManager.default.removeItem(at: meeting.recordingURL)
        if let t = meeting.transcriptURL { try? FileManager.default.removeItem(at: t) }

        // Remove from database
        if let record = fetchRecord(id: meeting.id) {
            context.delete(record)
            try? context.save()
        }

        meetings.removeAll { $0.id == meeting.id }
        logger.info("MeetingRepository: deleted \(meeting.id)")
    }

    func updateTitle(_ meeting: Meeting, title: String) {
        guard let record = fetchRecord(id: meeting.id) else { return }
        record.title = title
        record.updatedAt = Date()
        try? context.save()
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx].title = title
        }
    }

    func retryTranscription(_ meeting: Meeting) async {
        // Update status in DB
        if let record = fetchRecord(id: meeting.id) {
            record.transcriptionStatusRaw = "pending"
            record.updatedAt = Date()
            try? context.save()
        }

        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx].transcriptionStatus = .pending
        }

        let session = RecordingSession(
            id: meeting.id,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            outputURL: meeting.recordingURL,
            meetingApplication: meeting.meetingApplication
        )
        await TranscriptionQueue.shared.enqueue(session)
    }

    // MARK: - Update after transcription completes

    func refreshTranscriptionStatus(for sessionID: UUID) {
        guard let record = fetchRecord(id: sessionID) else { return }

        // Check if transcript file now exists on disk
        let recordingURL = baseURL.appendingPathComponent(record.recordingPath)
        let transcriptFile = recordingURL.deletingLastPathComponent()
            .appendingPathComponent(recordingURL.deletingPathExtension().lastPathComponent + "_transcript.md")

        if FileManager.default.fileExists(atPath: transcriptFile.path) {
            let relPath = transcriptFile.path.replacingOccurrences(of: baseURL.path + "/", with: "")
            record.transcriptPath = relPath
            record.transcriptionStatusRaw = "completed"
        } else {
            record.transcriptionStatusRaw = "failed:"
        }
        record.updatedAt = Date()
        try? context.save()
    }

    // MARK: - Filtering & Grouping

    func filtered(by filter: SidebarFilter) -> [Meeting] {
        let cal = Calendar.current
        let now = Date()
        switch filter {
        case .allMeetings: return meetings
        case .today:       return meetings.filter { cal.isDateInToday($0.startedAt) }
        case .thisWeek:
            let weekAgo = cal.date(byAdding: .day, value: -7, to: now)!
            return meetings.filter { $0.startedAt >= weekAgo }
        }
    }

    func grouped(by filter: SidebarFilter) -> [MeetingDateGroup] {
        let list = filtered(by: filter)
        let cal = Calendar.current
        let now = Date()
        var groups: [(label: String, meetings: [Meeting])] = []
        var seen: [String: Int] = [:]

        for meeting in list {
            let label: String
            if cal.isDateInToday(meeting.startedAt) {
                label = "Today"
            } else if cal.isDateInYesterday(meeting.startedAt) {
                label = "Yesterday"
            } else if meeting.startedAt >= cal.date(byAdding: .day, value: -7, to: now)! {
                let f = DateFormatter(); f.dateFormat = "EEEE"
                label = f.string(from: meeting.startedAt)
            } else {
                let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
                label = f.string(from: meeting.startedAt)
            }

            if let idx = seen[label] {
                groups[idx].meetings.append(meeting)
            } else {
                seen[label] = groups.count
                groups.append((label: label, meetings: [meeting]))
            }
        }
        return groups.map { MeetingDateGroup(id: $0.label, label: $0.label, meetings: $0.meetings) }
    }

    // MARK: - Private helpers

    private func fetchRecord(id: UUID) -> MeetingRecord? {
        try? context.fetch(
            FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private static func loadDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.isValid, !d.isIndefinite else { return 0 }
        return d.seconds
    }

    private static func formattedTitle(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM · HH:mm"
        return f.string(from: date)
    }
}
