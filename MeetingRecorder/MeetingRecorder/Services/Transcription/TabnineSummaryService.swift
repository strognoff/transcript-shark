//
//  TabnineSummaryService.swift
//  MeetingRecorder
//
//  Shells out to a local AI CLI provider to produce an AI summary of a
//  transcript. Provider, executable path, and prompt are read from UserDefaults
//  so users can customise them in Settings → AI Summary.
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

/// Default Tabnine path used when the user has not customised the setting.
nonisolated let kDefaultTabnineCLIPath = "/Users/jeffcechinel/.local/bin/tabnine"

/// UserDefaults key that stores the user-configured Tabnine executable path.
nonisolated let kTabnineCLIPathKey = "tabnineCLIPath"

/// Default OpenCode path used when the user has not customised the setting.
nonisolated let kDefaultOpenCodeCLIPath = "/usr/local/bin/opencode"

/// UserDefaults key that stores the user-configured OpenCode executable path.
nonisolated let kOpenCodeCLIPathKey = "openCodeCLIPath"

/// UserDefaults key that stores the selected AI summary provider.
nonisolated let kAISummaryProviderKey = "aiSummaryProvider"

/// Default instructions sent to the selected provider when the user has not customised the summary prompt.
nonisolated let kDefaultTabnineSummaryPrompt = """
You are a recording assistant. Summarise the following transcript concisely.
Structure your response with three short sections:
**Key Topics**, **Decisions Made**, and **Action Items**.
Be brief and specific. Omit filler and small talk.
"""

/// UserDefaults key that stores custom AI summary instructions.
nonisolated let kTabnineSummaryPromptKey = "tabnineSummaryPrompt"

// MARK: - Provider

enum AISummaryProvider: String, CaseIterable, Identifiable {
    case tabnine
    case openCode

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .tabnine: return "Tabnine"
        case .openCode: return "OpenCode"
        }
    }

    nonisolated var defaultExecutablePath: String {
        switch self {
        case .tabnine: return kDefaultTabnineCLIPath
        case .openCode: return kDefaultOpenCodeCLIPath
        }
    }

    nonisolated var executablePathKey: String {
        switch self {
        case .tabnine: return kTabnineCLIPathKey
        case .openCode: return kOpenCodeCLIPathKey
        }
    }

    nonisolated static func resolved(from rawValue: String?) -> AISummaryProvider {
        rawValue.flatMap(AISummaryProvider.init(rawValue:)) ?? .tabnine
    }
}

// MARK: - Errors

enum SummaryError: LocalizedError {
    case executableNotFound(provider: AISummaryProvider, path: String)
    case processFailed(provider: AISummaryProvider, code: Int32, stderr: String)
    case noOutput(provider: AISummaryProvider)

    nonisolated var errorDescription: String? {
        switch self {
        case .executableNotFound(let provider, let path):
            return "\(provider.displayName) executable not found at: \(path)\nUpdate the path in Settings → AI Summary."
        case .processFailed(let provider, let code, let stderr):
            let detail = stderr.isEmpty ? "exit code \(code)" : stderr
            return "\(provider.displayName) exited with an error: \(detail)"
        case .noOutput(let provider):
            return "\(provider.displayName) returned an empty response."
        }
    }
}

// MARK: - Service

actor TabnineSummaryService {

    static let shared = TabnineSummaryService()

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

    /// Resolves the selected AI summary provider, defaulting to Tabnine for backwards compatibility.
    nonisolated func resolvedProvider() -> AISummaryProvider {
        AISummaryProvider.resolved(from: UserDefaults.standard.string(forKey: kAISummaryProviderKey))
    }

    /// Resolves the summary instructions sent to the selected provider, using the default when no custom prompt is configured.
    nonisolated func resolvedSummaryPrompt() -> String {
        resolvedSummaryPrompt(override: nil)
    }

    /// Resolves summary instructions, preferring a nonblank per-recording override over the global prompt.
    nonisolated func resolvedSummaryPrompt(override promptOverride: String?) -> String {
        let override = promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return override
        }

        let stored = UserDefaults.standard.string(forKey: kTabnineSummaryPromptKey) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kDefaultTabnineSummaryPrompt : trimmed
    }

    /// Resolves the executable path for a provider, using that provider's default when no custom path is configured.
    nonisolated func resolvedExecutablePath(for provider: AISummaryProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: provider.executablePathKey) ?? ""
        return stored.isEmpty ? provider.defaultExecutablePath : stored
    }

    /// Generates a summary using the selected local AI CLI and persists it to disk.
    /// - Parameters:
    ///   - transcript: The full transcript text to summarise.
    ///   - recordingURL: The recording's audio file URL — used to derive the save path.
    ///   - promptOverride: Optional per-recording instructions that override the global prompt when nonblank.
    func summarise(transcript: String, recordingURL: URL, promptOverride: String? = nil) async throws -> String {
        let provider = resolvedProvider()
        let executablePath = resolvedExecutablePath(for: provider)
        let prompt = resolvedSummaryPrompt(override: promptOverride)

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            logger.error("TabnineSummaryService: \(provider.displayName) binary not found at \(executablePath)")
            throw SummaryError.executableNotFound(provider: provider, path: executablePath)
        }

        logger.info("TabnineSummaryService: running \(provider.displayName) at \(executablePath)")
        let output = try await runProcess(
            provider: provider,
            executable: executablePath,
            prompt: prompt,
            transcript: transcript
        )

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummaryError.noOutput(provider: provider)
        }

        logger.info("TabnineSummaryService: received \(trimmed.count) chars — saving to disk")
        let saveURL = summaryURL(for: recordingURL)
        try? trimmed.write(to: saveURL, atomically: true, encoding: .utf8)

        return trimmed
    }

    // MARK: - Helpers

    private func runProcess(provider: AISummaryProvider, executable: String, prompt: String, transcript: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments(for: provider, prompt: prompt, transcript: transcript)
            process.environment = Self.enrichedEnvironment()

            let stdinPipe: Pipe?
            if provider == .tabnine {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            } else {
                stdinPipe = nil
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let code = proc.terminationStatus

                if code == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    logger.error("TabnineSummaryService: \(provider.displayName) exit \(code) stderr=\(stderr)")
                    continuation.resume(throwing: SummaryError.processFailed(provider: provider, code: code, stderr: stderr))
                }
            }

            do {
                try process.run()
                if let stdinPipe, let data = transcript.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                    stdinPipe.fileHandleForWriting.closeFile()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated func arguments(for provider: AISummaryProvider, prompt: String, transcript: String) -> [String] {
        switch provider {
        case .tabnine:
            return [
                "--skip-trust",
                "--prompt", prompt,
                "-o", "text",
            ]
        case .openCode:
            return [
                "run",
                "--format", "default",
                "--title", "Transcript Shark Summary",
                prompt + "\n\nTranscript:\n" + transcript,
            ]
        }
    }

    /// Returns a copy of the current process environment with PATH augmented to
    /// include common CLI install locations that are absent when an app is
    /// launched directly from macOS (not from a shell).
    private static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()

        let extraPaths: [String] = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "\(home)/.nvm/versions/node/current/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
        ]

        let existingPath = env["PATH"] ?? ""
        let combined = (extraPaths + existingPath.split(separator: ":").map(String.init))
            .removingDuplicates()
            .joined(separator: ":")
        env["PATH"] = combined

        env["TABNINE_CLI_TRUST_WORKSPACE"] = "true"

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.path ?? (home + "/Library/Application Support")
        let agentDir = appSupport + "/MeetingRecorder/TabnineAgent"
        try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
        env["TABNINE_AGENT_DIR"] = agentDir

        return env
    }
}
