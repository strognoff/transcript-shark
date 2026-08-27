//
//  TranscriptionQueue.swift
//  MeetingRecorder
//
//  Actor that serialises transcription jobs. Each completed recording is
//  enqueued here; jobs run one at a time to avoid overloading SFSpeechRecognizer.
//

import Foundation
import AVFoundation
import CoreMedia
import UserNotifications
import Speech
import OSLog

extension Notification.Name {
    nonisolated(unsafe) static let transcriptionJobCompleted = Notification.Name("com.transcript-shark.transcriptionJobCompleted")
}

// MARK: - Job

struct TranscriptionJob: Sendable {
    let session: RecordingSession
    var status: TranscriptionStatus
    let enqueuedAt: Date
    var transcriptURL: URL?
    var errorMessage: String?
    var progress: Double = 0.0
    var progressLabel: String = ""

    nonisolated init(session: RecordingSession) {
        self.session = session
        self.status = .pending
        self.enqueuedAt = Date()
    }
}

enum TranscriptionStatus: Sendable, Equatable {
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

    func progress(for id: UUID) -> (value: Double, label: String) {
        guard let job = jobs[id] else { return (0, "") }
        return (job.progress, job.progressLabel)
    }

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
            let result = try await transcribeSpeakerAttributed(session: job.session, jobID: id)
            let transcriptURL = try generator.write(session: job.session, result: result)

            job.status = .completed
            job.transcriptURL = transcriptURL
            jobs[id] = job

            logger.info("TranscriptionQueue: completed \(id) → \(transcriptURL.lastPathComponent)")
            let completedID = id
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .transcriptionJobCompleted,
                    object: nil,
                    userInfo: ["sessionID": completedID]
                )
            }
            await sendNotification(title: "Transcript ready", body: job.session.outputURL.deletingLastPathComponent().lastPathComponent)

        } catch {
            let message = error.localizedDescription
            job.status = .failed(message)
            job.errorMessage = message
            jobs[id] = job
            logger.error("TranscriptionQueue: failed \(id) — \(message)")
            let failedID = id
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .transcriptionJobCompleted,
                    object: nil,
                    userInfo: ["sessionID": failedID]
                )
            }
            await sendNotification(title: "Transcription failed", body: message)
        }

        isProcessing = false
        processNextIfIdle()
    }

    // MARK: - Speaker-attributed transcription

    private func setProgress(_ id: UUID, value: Double, label: String) {
        jobs[id]?.progress = value
        jobs[id]?.progressLabel = label
    }

    /// Transcribes the microphone and system audio sidecar files separately,
    /// then merges the results sorted by timestamp with speaker labels.
    /// Falls back to the combined recording (Speaker.unknown) if sidecars are absent.
    private func transcribeSpeakerAttributed(session: RecordingSession, jobID: UUID) async throws -> TranscriptResult {
        let base = session.outputURL.deletingPathExtension().lastPathComponent
        let dir  = session.outputURL.deletingLastPathComponent()
        let micURL    = dir.appendingPathComponent("\(base)_mic.caf")
        let systemURL = dir.appendingPathComponent("\(base)_system.caf")

        let fm = FileManager.default
        let micExists    = fm.fileExists(atPath: micURL.path)
        let systemExists = fm.fileExists(atPath: systemURL.path)

        guard micExists || systemExists else {
            logger.warning("TranscriptionQueue: no sidecar files found — falling back to combined audio")
            setProgress(jobID, value: 0.5, label: "Transcribing…")
            let result = try await transcriber.transcribe(audioURL: session.outputURL, language: nil)
            setProgress(jobID, value: 1.0, label: "Done")
            return result
        }

        logger.info("TranscriptionQueue: transcribing with speaker attribution (mic=\(micExists), system=\(systemExists))")

        // Transcribe sidecars sequentially — running both concurrently floods the Apple
        // Speech server with up to 8 tasks at once (4 chunks × 2 tracks), which causes
        // rate-limiting that silently returns empty results for the mic chunks.
        setProgress(jobID, value: 0.0, label: "Transcribing mic…")
        let micResult: TranscriptResult?
        if micExists {
            do { micResult = try await transcriber.transcribe(audioURL: micURL, language: nil) }
            catch { logger.error("TranscriptionQueue: mic transcription failed — \(error.localizedDescription)"); micResult = nil }
        } else {
            micResult = nil
        }

        setProgress(jobID, value: 0.45, label: "Transcribing system audio…")
        let systemResult: TranscriptResult?
        if systemExists {
            do { systemResult = try await transcriber.transcribe(audioURL: systemURL, language: nil) }
            catch { logger.error("TranscriptionQueue: system transcription failed — \(error.localizedDescription)"); systemResult = nil }
        } else {
            systemResult = nil
        }

        setProgress(jobID, value: 0.85, label: "Finishing up…")

        // Tag and collect all segments
        var all: [TranscriptSegment] = []

        if let r = micResult {
            let tagged = r.segments.map { seg in
                TranscriptSegment(startTime: seg.startTime, endTime: seg.endTime, text: seg.text, speaker: .me)
            }
            all.append(contentsOf: tagged)
            logger.info("TranscriptionQueue: mic — \(r.segments.count) segments")
        }

        if let r = systemResult {
            let tagged = r.segments.map { seg in
                TranscriptSegment(startTime: seg.startTime, endTime: seg.endTime, text: seg.text, speaker: .them)
            }
            all.append(contentsOf: tagged)
            logger.info("TranscriptionQueue: system — \(r.segments.count) segments")
        }

        // Fall back to combined audio if both sidecars failed to produce results
        if all.isEmpty {
            logger.warning("TranscriptionQueue: sidecar transcription produced no segments — falling back to combined audio")
            return try await transcriber.transcribe(audioURL: session.outputURL, language: nil)
        }

        // Merge and sort by start time
        all.sort { $0.startTime < $1.startTime }

        let fullText = all.map(\.text).joined(separator: " ")
        let duration = max(micResult?.duration ?? 0, systemResult?.duration ?? 0)
        let language = micResult?.detectedLanguage ?? systemResult?.detectedLanguage

        setProgress(jobID, value: 1.0, label: "Done")
        return TranscriptResult(text: fullText, segments: all, detectedLanguage: language, duration: duration)
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
