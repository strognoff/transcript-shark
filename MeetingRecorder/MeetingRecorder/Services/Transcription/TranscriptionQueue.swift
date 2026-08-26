//
//  TranscriptionQueue.swift
//  MeetingRecorder
//
//  Actor that queues completed recordings for transcription.
//  In Milestone 2 this is a stub — it accepts jobs and logs them.
//  Full implementation (AppleSpeechTranscriber) is Milestone 4.
//

import Foundation
import OSLog

// MARK: - Job

struct TranscriptionJob: Sendable {
    let session: RecordingSession
    var status: TranscriptionStatus
    let enqueuedAt: Date

    nonisolated init(session: RecordingSession) {
        self.session = session
        self.status = .pending
        self.enqueuedAt = Date()
    }
}

enum TranscriptionStatus: Sendable {
    case pending
    case processing
    case completed
    case failed(String)
}

// MARK: - Queue

actor TranscriptionQueue {

    private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "TranscriptionQueue")
    private var jobs: [UUID: TranscriptionJob] = [:]

    static let shared = TranscriptionQueue()
    private init() {}

    /// Enqueue a completed session for transcription.
    func enqueue(_ session: RecordingSession) {
        let job = TranscriptionJob(session: session)
        jobs[session.id] = job
        logger.info("TranscriptionQueue: enqueued session \(session.id) — \(session.outputURL.lastPathComponent)")
        // Milestone 4: kick off AppleSpeechTranscriber here
    }

    /// Current queue snapshot — for UI display in Milestone 5.
    func allJobs() -> [TranscriptionJob] {
        Array(jobs.values).sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    /// Job count for diagnostics.
    func pendingCount() -> Int {
        jobs.values.filter {
            if case .pending = $0.status { return true }
            return false
        }.count
    }
}
