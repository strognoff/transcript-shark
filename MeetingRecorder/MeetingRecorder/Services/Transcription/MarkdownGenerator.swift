//
//  MarkdownGenerator.swift
//  MeetingRecorder
//
//  Produces a transcript.md file from a TranscriptResult + RecordingSession.
//

import Foundation

struct MarkdownGenerator {

    // MARK: - Generate

    nonisolated func generate(session: RecordingSession, result: TranscriptResult, title: String? = nil) -> String {
        let resolvedTitle = title ?? defaultTitle(for: session)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        let date        = dateFmt.string(from: session.startedAt)
        let started     = timeFmt.string(from: session.startedAt)
        let ended       = session.endedAt.map { timeFmt.string(from: $0) } ?? "-"
        let durationSec = Int(result.duration)
        let shortID     = String(session.id.uuidString.prefix(18))
        let audioFile   = session.outputURL.lastPathComponent
        let app         = session.meetingApplication

        var lines: [String] = []

        // YAML front matter
        lines += [
            "---",
            "id: \(shortID)",
            #"title: "\#(resolvedTitle)""#,
            "date: \(date)",
            "started: \(started)",
            "duration_seconds: \(durationSec)",
            #"meeting_application: "\#(app)""#,
            #"audio_file: "\#(audioFile)""#,
            "---",
            "",
        ]

        // Title
        lines += ["# \(resolvedTitle)", ""]

        // Metadata block
        lines += [
            "**Date:** \(formattedDate(session.startedAt))",
            "**Started:** \(started)",
            "**Ended:** \(ended)",
            "**Duration:** \(formattedDuration(durationSec))",
            "**Application:** \(app)",
            "",
        ]

        // Transcript section
        lines += ["## Transcript", ""]

        if result.segments.isEmpty {
            lines += [result.text, ""]
        } else {
            var lastBucket = -1
            var paragraph = ""
            for segment in result.segments {
                let bucket = (Int(segment.startTime) / 60) * 60
                if bucket != lastBucket {
                    if !paragraph.isEmpty {
                        lines += [paragraph.trimmingCharacters(in: .whitespaces), ""]
                        paragraph = ""
                    }
                    lines += ["### \(formatTimestamp(segment.startTime))", ""]
                    lastBucket = bucket
                }
                let word = segment.text.trimmingCharacters(in: .whitespaces)
                paragraph += word + " "
            }
            if !paragraph.isEmpty {
                lines += [paragraph.trimmingCharacters(in: .whitespaces), ""]
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Write to disk

    nonisolated func write(session: RecordingSession, result: TranscriptResult, title: String? = nil) throws -> URL {
        let content = generate(session: session, result: result, title: title)
        let dir = session.outputURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("transcript.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    nonisolated private func defaultTitle(for session: RecordingSession) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy 'at' HH:mm"
        return "Meeting — \(f.string(from: session.startedAt))"
    }

    nonisolated private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    nonisolated private func formattedDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m) minute\(m == 1 ? "" : "s")" }
        return "\(s) seconds"
    }

    nonisolated private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
