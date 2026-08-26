//
//  ContentView.swift
//  MeetingRecorder
//
//  Milestone 2 — UI driven by RecorderState from RecordingCoordinator.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var coordinator = RecordingCoordinator()

    var body: some View {
        VStack(spacing: 24) {
            switch coordinator.recorderState {

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
        .frame(width: 420, height: 300)
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

            Button("Start Recording") {
                Task { @MainActor in await coordinator.startRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
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

            Text(durationString(coordinator.duration))
                .font(.system(.title, design: .monospaced))
                .foregroundStyle(.secondary)

            Button("Stop Recording") {
                Task { @MainActor in await coordinator.stopRecording() }
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
                    coordinator.reset()
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
                coordinator.reset()
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
}
