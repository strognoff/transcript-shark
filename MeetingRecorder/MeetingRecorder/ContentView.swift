//
//  ContentView.swift
//  MeetingRecorder
//
//  Milestone 3 — Main window UI, driven by AppState from environment.
//  Closing this window does NOT quit the app (menu bar persists).
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            switch appState.recorderState {

            case .idle:
                idleView

            case .recording:
                recordingView

            case .finished(let session):
                finishedView(session: session)

            case .failed(let error):
                failedView(error: error)
            }
        }
        .padding(40)
        .frame(width: 420, height: 320)
        .overlay(alignment: .bottomTrailing) {
            Text(buildLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(8)
        }
    }

    // MARK: - State views

    private var idleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.red)

            Text("Meeting Recorder")
                .font(.title2.bold())

            Text("Waiting for a meeting…")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Start Recording Manually") {
                Task { @MainActor in await appState.startRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            // DEBUG: manually transcribe an existing recording
            Button("Transcribe Existing File…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.mpeg4Movie]
                panel.directoryURL = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first?.appendingPathComponent("MeetingRecorder/Recordings")
                panel.message = "Select a recording to transcribe"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let session = RecordingSession(
                    startedAt: Date(),
                    endedAt: Date(),
                    outputURL: url
                )
                Task { await TranscriptionQueue.shared.enqueue(session) }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.secondary)
        }
    }

    private var recordingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "record.circle")
                .font(.system(size: 72))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)

            Text("Recording")
                .font(.title2.bold())

            Text(durationString(appState.duration))
                .font(.system(.title, design: .monospaced))
                .foregroundStyle(.secondary)

            Button("Stop Recording") {
                Task { @MainActor in await appState.stopRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .controlSize(.large)
        }
    }

    private func finishedView(session: RecordingSession) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Recording saved")
                .font(.title2.bold())

            if let duration = session.duration {
                Text(durationString(duration))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(session.outputURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.outputURL])
                }
                .buttonStyle(.bordered)

                Button("Record Again") {
                    appState.reset()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func failedView(error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Recording failed")
                .font(.title2.bold())

            Text(error.localizedDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                appState.reset()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private func durationString(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private var buildLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
}
