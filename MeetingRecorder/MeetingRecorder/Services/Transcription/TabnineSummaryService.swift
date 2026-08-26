//
//  TabnineSummaryService.swift
//  MeetingRecorder
//
//  Shells out to the local Tabnine CLI to produce an AI summary of a meeting
//  transcript. The executable path is read from UserDefaults so users can
//  override it in Settings → AI Summary.
//
//  Invocation:
//    echo "<transcript>" | tabnine --prompt "<system prompt>" -o text
//

import Foundation
import OSLog

// MARK: - Helpers

private extension Array where Element: Hashable {
    /// Returns the array with duplicates removed, preserving first-occurrence order.
    nonisolated func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private nonisolated let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "TabnineSummaryService")

/// Default path used when the user has not customised the setting.
nonisolated let kDefaultTabnineCLIPath = "/Users/jeffcechinel/.local/bin/tabnine"

/// UserDefaults key that stores the user-configured Tabnine executable path.
nonisolated let kTabnineCLIPathKey = "tabnineCLIPath"

// MARK: - Errors

enum SummaryError: LocalizedError {
    case executableNotFound(String)
    case processFailed(Int32, String)
    case noOutput

    nonisolated var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Tabnine executable not found at: \(path)\nUpdate the path in Settings → AI Summary."
        case .processFailed(let code, let stderr):
            let detail = stderr.isEmpty ? "exit code \(code)" : stderr
            return "Tabnine exited with an error: \(detail)"
        case .noOutput:
            return "Tabnine returned an empty response."
        }
    }
}

// MARK: - Service

actor TabnineSummaryService {

    static let shared = TabnineSummaryService()

    private static let systemPrompt = """
        You are a meeting assistant. Summarise the following meeting transcript concisely. 
        Structure your response with three short sections: 
        **Key Topics**, **Decisions Made**, and **Action Items**. 
        Be brief and specific. Omit filler and small talk.
        """

    // MARK: - Public API

    /// Returns the URL where the summary for a given recording is stored.
    nonisolated func summaryURL(for recordingURL: URL) -> URL {
        let base = recordingURL.deletingPathExtension().lastPathComponent
        let dir  = recordingURL.deletingLastPathComponent()
        return dir.appendingPathComponent("\(base)_summary.md")
    }

    /// Loads a previously persisted summary from disk, or nil if none exists.
    nonisolated func loadSummary(for recordingURL: URL) -> String? {
        let url = summaryURL(for: recordingURL)
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return content
    }

    /// Generates a summary using the local Tabnine CLI and persists it to disk.
    /// - Parameters:
    ///   - transcript: The full transcript text to summarise.
    ///   - recordingURL: The recording's audio file URL — used to derive the save path.
    func summarise(transcript: String, recordingURL: URL) async throws -> String {
        let executablePath = resolvedExecutablePath()

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            logger.error("TabnineSummaryService: binary not found at \(executablePath)")
            throw SummaryError.executableNotFound(executablePath)
        }

        logger.info("TabnineSummaryService: running tabnine at \(executablePath)")
        let output = try await runProcess(executable: executablePath, transcript: transcript)

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummaryError.noOutput
        }

        logger.info("TabnineSummaryService: received \(trimmed.count) chars — saving to disk")
        let saveURL = summaryURL(for: recordingURL)
        try? trimmed.write(to: saveURL, atomically: true, encoding: .utf8)

        return trimmed
    }

    // MARK: - Helpers

    private func resolvedExecutablePath() -> String {
        let stored = UserDefaults.standard.string(forKey: kTabnineCLIPathKey) ?? ""
        return stored.isEmpty ? kDefaultTabnineCLIPath : stored
    }

    private func runProcess(executable: String, transcript: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "--skip-trust",
                "--prompt", Self.systemPrompt,
                "-o", "text",
            ]

            // Apps launched from macOS inherit a minimal PATH that excludes user
            // shell paths. The Tabnine CLI is a Node.js script, so `node` must be
            // findable. Build an enriched PATH covering the most common install locations.
            process.environment = Self.enrichedEnvironment()

            // Pipe transcript into stdin
            let stdinPipe  = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput  = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let code = proc.terminationStatus

                if code == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    logger.error("TabnineSummaryService: exit \(code) stderr=\(stderr)")
                    continuation.resume(throwing: SummaryError.processFailed(code, stderr))
                }
            }

            do {
                try process.run()
                // Write transcript then close stdin so tabnine reads EOF
                if let data = transcript.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Returns a copy of the current process environment with PATH augmented to
    /// include common Node.js install locations that are absent when an app is
    /// launched directly from macOS (not from a shell).
    private static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()

        let extraPaths: [String] = [
            "/usr/local/bin",           // Homebrew (Intel) / system node
            "/opt/homebrew/bin",        // Homebrew (Apple Silicon)
            "/opt/homebrew/sbin",
            "\(home)/.nvm/versions/node/current/bin", // nvm generic symlink
            "\(home)/.local/bin",       // pipx / manual installs (tabnine itself)
            "/usr/bin",
            "/bin",
        ]

        // Prepend extra paths to existing PATH so user's node wins if already present
        let existingPath = env["PATH"] ?? ""
        let combined = (extraPaths + existingPath.split(separator: ":").map(String.init))
            .removingDuplicates()
            .joined(separator: ":")
        env["PATH"] = combined

        // Tell the CLI to trust the workspace without interactive confirmation
        env["TABNINE_CLI_TRUST_WORKSPACE"] = "true"

        // Redirect the CLI's agent directory to our own app-support folder so its
        // cache files don't collide with the Tabnine agent that runs this very session
        // (which would cause EACCES on org_policy_cache.json)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.path ?? (home + "/Library/Application Support")
        let agentDir = appSupport + "/MeetingRecorder/TabnineAgent"
        try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
        env["TABNINE_AGENT_DIR"] = agentDir

        return env
    }
}
