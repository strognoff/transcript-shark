//
//  MarkdownGenerator.swift
//  MeetingRecorder
//
//  Produces a transcript.md file from a TranscriptResult + RecordingSession.
//

import Foundation

struct MarkdownGenerator: Sendable {

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
        // Prefer wall-clock session duration (from stored let properties); fall back to audio duration
        let sessionDuration = session.endedAt.map { $0.timeIntervalSince(session.startedAt) }
        let durationSec = Int(sessionDuration ?? result.duration)
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
            let hasAttribution = result.segments.contains { $0.speaker != .unknown }

            if hasAttribution {
                lines += transcriptLinesWithSpeakers(result.segments)
            } else {
                lines += transcriptLinesByTimestamp(result.segments)
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Transcript rendering helpers

    /// Renders segments grouped by consecutive speaker, emitting a bold speaker
    /// label and timestamp at each speaker change.
    nonisolated private func transcriptLinesWithSpeakers(_ segments: [TranscriptSegment]) -> [String] {
        var lines: [String] = []
        var currentSpeaker: Speaker? = nil
        var paragraph = ""

        for segment in segments {
            let speaker = segment.speaker

            if speaker != currentSpeaker {
                // Flush previous paragraph
                if !paragraph.isEmpty {
                    lines += [paragraph.trimmingCharacters(in: .whitespaces), ""]
                    paragraph = ""
                }
                // Emit speaker header: bold label + timestamp
                let label: String
                switch speaker {
                case .me:      label = "**Me**"
                case .them:    label = "**Them**"
                case .unknown: label = "**—**"
                }
                lines += ["\(label) `\(formatTimestamp(segment.startTime))`", ""]
                currentSpeaker = speaker
            }

            paragraph += segment.text.trimmingCharacters(in: .whitespaces) + " "
        }

        if !paragraph.isEmpty {
            lines += [paragraph.trimmingCharacters(in: .whitespaces), ""]
        }

        return lines
    }

    /// Renders segments grouped by minute bucket (legacy / no attribution).
    nonisolated private func transcriptLinesByTimestamp(_ segments: [TranscriptSegment]) -> [String] {
        var lines: [String] = []
        var lastBucket = -1
        var paragraph = ""

        for segment in segments {
            let bucket = (Int(segment.startTime) / 60) * 60
            if bucket != lastBucket {
                if !paragraph.isEmpty {
                    lines += [paragraph.trimmingCharacters(in: .whitespaces), ""]
                    paragraph = ""
                }
                lines += ["### \(formatTimestamp(segment.startTime))", ""]
                lastBucket = bucket
            }
            paragraph += segment.text.trimmingCharacters(in: .whitespaces) + " "
        }

        if !paragraph.isEmpty {
            lines += [paragraph.trimmingCharacters(in: .whitespaces), ""]
        }

        return lines
    }

    // MARK: - Write to disk

    nonisolated func write(session: RecordingSession, result: TranscriptResult, title: String? = nil) throws -> URL {
        let content = generate(session: session, result: result, title: title)
        let dir = session.outputURL.deletingLastPathComponent()
        // Name is tied to the recording file so each recording has its own transcript
        let recordingName = session.outputURL.deletingPathExtension().lastPathComponent
        let url = dir.appendingPathComponent("\(recordingName)_transcript.md")
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
