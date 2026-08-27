//
//  TranscriptionIntegrationTests.swift
//  MeetingRecorderTests
//
//  Integration test: transcribes the most recent real recording and prints
//  the resulting Markdown. Run individually with the play button in Test Navigator.
//

import Testing
import Foundation
import Speech
@testable import MeetingRecorder

@MainActor
struct TranscriptionIntegrationTests {

    @Test("Transcribe most recent recording", .timeLimit(.minutes(5)))
    func transcribeMostRecentRecording() async throws {
        // Request Speech Recognition permission — must happen before calling transcriber
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            Issue.record("Speech Recognition permission not granted — grant it in System Settings and retry")
            return
        }

        let recordingsDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("MeetingRecorder/Recordings")

        let files = try FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )
        .filter { $0.pathExtension == "mp4" }
        .sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 > d2
        }

        guard let audioURL = files.first else {
            Issue.record("No .mp4 recordings found in \(recordingsDir.path)")
            return
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Transcribing: \(audioURL.lastPathComponent)")
        print("Size: \(sizeStr)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        let transcriber = AppleSpeechTranscriber()
        let result = try await transcriber.transcribe(audioURL: audioURL, language: nil)

        print("Duration : \(String(format: "%.1f", result.duration))s")
        print("Segments : \(result.segments.count)")
        print("Language : \(result.detectedLanguage ?? "unknown")")
        print("--- TRANSCRIPT ---")
        print(result.text)
        print("--- END TRANSCRIPT ---")

        let session = RecordingSession(
            startedAt: Date().addingTimeInterval(-result.duration),
            endedAt: Date(),
            outputURL: audioURL
        )

        let generator = MarkdownGenerator()
        let markdown = generator.generate(session: session, result: result)

        print("--- MARKDOWN ---")
        print(markdown)
        print("--- END MARKDOWN ---")

        let transcriptURL = try generator.write(session: session, result: result)
        print("Transcript written to: \(transcriptURL.path)")

        #expect(!result.text.isEmpty, "Transcript text should not be empty")
        #expect(result.duration > 0, "Duration should be positive")
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path), "transcript.md should exist")
    }

    /// Exercises the SFSpeechAudioBufferRecognitionRequest path used for raw PCM .caf sidecars.
    /// This is the path that was failing with "No speech detected" / "Cannot Open" before the fix.
    @Test("Transcribe CAF sidecar with buffer API (mic + system speaker attribution)", .timeLimit(.minutes(10)))
    func transcribeCAFSidecarsWithSpeakerAttribution() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            Issue.record("Speech Recognition permission not granted")
            return
        }

        let recordingsDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("MeetingRecorder/Recordings")

        // Find the most recent pair of _mic.caf + _system.caf sidecars
        let allFiles = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        let micCAFs = allFiles
            .filter { $0.lastPathComponent.hasSuffix("_mic.caf") }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }

        guard let micURL = micCAFs.first else {
            Issue.record("No _mic.caf sidecar files found in \(recordingsDir.path)")
            return
        }

        let base = micURL.lastPathComponent.replacingOccurrences(of: "_mic.caf", with: "")
        let systemURL = micURL.deletingLastPathComponent().appendingPathComponent("\(base)_system.caf")

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Mic   : \(micURL.lastPathComponent)")
        print("System: \(systemURL.lastPathComponent) exists=\(FileManager.default.fileExists(atPath: systemURL.path))")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        let transcriber = AppleSpeechTranscriber()

        // Transcribe both concurrently — this is the exact code path that was failing
        async let micTask = transcriber.transcribe(audioURL: micURL, language: nil)
        async let systemTask = FileManager.default.fileExists(atPath: systemURL.path)
            ? transcriber.transcribe(audioURL: systemURL, language: nil)
            : nil

        let (micResult, systemResult) = try await (micTask, systemTask)

        print("Mic    — duration: \(String(format: "%.1f", micResult.duration))s, segments: \(micResult.segments.count)")
        if let sys = systemResult {
            print("System — duration: \(String(format: "%.1f", sys.duration))s, segments: \(sys.segments.count)")
        }

        #expect(micResult.segments.count > 0, "Mic track must produce segments — buffer API path broken if this fails")
        #expect(!micResult.text.isEmpty, "Mic transcript must not be empty")

        print("--- MIC TRANSCRIPT (first 500 chars) ---")
        print(String(micResult.text.prefix(500)))
        if let sys = systemResult {
            print("--- SYSTEM TRANSCRIPT (first 500 chars) ---")
            print(String(sys.text.prefix(500)))
        }
    }
}
