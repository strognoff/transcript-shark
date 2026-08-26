//
//  TranscriptionQueue.swift
//  MeetingRecorder
//
//  Actor that serialises transcription jobs. Each completed recording is
//  enqueued here; jobs run one at a time to avoid overloading SFSpeechRecognizer.
//

import Foundation
import UserNotifications
import Speech
import OSLog

// MARK: - Job

struct TranscriptionJob: Sendable {
    let session: RecordingSession
    var status: TranscriptionStatus
    let enqueuedAt: Date
    var transcriptURL: URL?
    var errorMessage: String?

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
    private var isProcessing = false
    private var pendingIDs: [UUID] = []

    /// Injected service — defaults to AppleSpeechTranscriber.
    private let transcriber: any TranscriptionService
    private let generator = MarkdownGenerator()

    static let shared = TranscriptionQueue()

    private init(transcriber: any TranscriptionService = AppleSpeechTranscriber()) {
        self.transcriber = transcriber
    }

    // MARK: - Enqueue

    func enqueue(_ session: RecordingSession) {
        let job = TranscriptionJob(session: session)
        jobs[session.id] = job
        pendingIDs.append(session.id)
        logger.info("TranscriptionQueue: enqueued \(session.id) — \(session.outputURL.lastPathComponent)")
        processNextIfIdle()
    }

    // MARK: - Retry

    func retry(sessionID: UUID) {
        guard var job = jobs[sessionID] else { return }
        guard case .failed = job.status else { return }
        job.status = .pending
        job.errorMessage = nil
        jobs[sessionID] = job
        pendingIDs.append(sessionID)
        logger.info("TranscriptionQueue: retrying \(sessionID)")
        processNextIfIdle()
    }

    // MARK: - Query

    func allJobs() -> [TranscriptionJob] {
        Array(jobs.values).sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    func job(for id: UUID) -> TranscriptionJob? { jobs[id] }

    // MARK: - Processing

    private func processNextIfIdle() {
        guard !isProcessing, let nextID = pendingIDs.first else { return }
        pendingIDs.removeFirst()
        isProcessing = true
        Task { await process(id: nextID) }
    }

    private func process(id: UUID) async {
        guard var job = jobs[id] else { isProcessing = false; return }

        job.status = .processing
        jobs[id] = job
        logger.info("TranscriptionQueue: processing \(id)")

        // Ensure Speech permission is granted before calling the transcriber
        await requestSpeechPermissionIfNeeded()

        do {
            let result = try await transcriber.transcribe(
                audioURL: job.session.outputURL,
                language: nil
            )
            let transcriptURL = try generator.write(session: job.session, result: result)

            job.status = .completed
            job.transcriptURL = transcriptURL
            jobs[id] = job

            logger.info("TranscriptionQueue: completed \(id) → \(transcriptURL.lastPathComponent)")
            await sendNotification(title: "Transcript ready", body: job.session.outputURL.deletingLastPathComponent().lastPathComponent)

        } catch {
            let message = error.localizedDescription
            job.status = .failed(message)
            job.errorMessage = message
            jobs[id] = job
            logger.error("TranscriptionQueue: failed \(id) — \(message)")
            await sendNotification(title: "Transcription failed", body: message)
        }

        isProcessing = false
        processNextIfIdle()
    }

    // MARK: - Permissions

    private func requestSpeechPermissionIfNeeded() async {
        guard SFSpeechRecognizer.authorizationStatus() != .authorized else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Notification

    private func sendNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()

        // Request permission if not yet granted
        _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )

        try? await center.add(request)
    }
}
