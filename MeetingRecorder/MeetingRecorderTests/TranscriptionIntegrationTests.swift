//
//  TranscriptionIntegrationTests.swift
//  MeetingRecorderTests
//
//  Integration test: transcribes the most recent real recording and prints
//  the resulting Markdown. Run individually with the play button in Test Navigator.
//

import Testing
import Foundation
@testable import MeetingRecorder

struct TranscriptionIntegrationTests {

    @Test("Transcribe most recent recording", .timeLimit(.minutes(5)))
    func transcribeMostRecentRecording() async throws {
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
}
