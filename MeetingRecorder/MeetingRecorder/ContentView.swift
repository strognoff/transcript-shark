//
//  ContentView.swift
//  MeetingRecorder
//
//  Milestone 5 — Root view. Shows LibraryView (three-column) as the main
//  interface. Recording state is accessible via the menu bar.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        LibraryView()
            .environmentObject(appState)
            .overlay(alignment: .bottomTrailing) {
                recordingBanner
            }
            .overlay(alignment: .bottom) {
                permissionErrorBanner
            }
            .overlay(alignment: .bottomTrailing) {
                Text(buildLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                    .padding(.trailing, 8)
            }
            // Keyboard shortcuts (hidden buttons register ⌘N, ⌘⇧R, ⌘,)
            .background(
                Group {
                    // ⌘N — Start manual recording
                    Button("") {
                        guard case .idle = appState.recorderState else { return }
                        Task { @MainActor in await appState.startRecording() }
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .hidden()

                    // ⌘⇧R — Start / stop recording
                    Button("") {
                        Task { @MainActor in
                            if appState.isRecording {
                                await appState.stopRecording()
                            } else {
                                await appState.startRecording()
                            }
                        }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .hidden()

                    // ⌘, — Open Settings
                    Button("") {
                        NotificationCenter.default.post(name: .showSettings, object: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    .hidden()
                }
            )
    }

    // MARK: - Recording banner (shown during active recording)

    @ViewBuilder
    private var recordingBanner: some View {
        if case .recording = appState.recorderState {
            HStack(spacing: 10) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text("Recording — \(durationString(appState.duration))")
                    .font(.system(.callout, design: .monospaced))
                Button("Stop") {
                    Task { @MainActor in await appState.stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
        }
    }

    // MARK: - Permission error banner

    @ViewBuilder
    private var permissionErrorBanner: some View {
        if let error = appState.permissionError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Screen Recording Permission Required", systemImage: "exclamationmark.shield")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .controlSize(.small)
                    Button("Dismiss") {
                        appState.permissionError = nil
                    }
                    .controlSize(.small)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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
