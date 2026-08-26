//
//  MeetingDetailView.swift
//  MeetingRecorder
//
//  Right column: metadata, audio player, transcript viewer, actions.
//

import SwiftUI
import AVFoundation

struct MeetingDetailView: View {

    let meeting: Meeting
    let onDelete: (Meeting) -> Void
    let onRetry:  (Meeting) -> Void

    @StateObject private var player = AudioPlayerViewModel()
    @State private var showRawMarkdown = false
    @State private var searchText = ""
    @State private var transcriptContent: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                audioPlayerSection
                Divider()
                transcriptSection
            }
            .padding(24)
        }
        .navigationTitle(meeting.title)
        .searchable(text: $searchText, prompt: "Search transcript")
        .toolbar { toolbarItems }
        .onAppear {
            player.load(url: meeting.recordingURL)
            loadTranscript()
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Label("Date", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                    Text(formattedDate(meeting.startedAt))
                }
                GridRow {
                    Label("Started", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Text(formattedTime(meeting.startedAt))
                }
                if let endedAt = meeting.endedAt {
                    GridRow {
                        Label("Ended", systemImage: "clock.fill")
                            .foregroundStyle(.secondary)
                        Text(formattedTime(endedAt))
                    }
                }
                if let duration = meeting.duration, duration > 0 {
                    GridRow {
                        Label("Duration", systemImage: "timer")
                            .foregroundStyle(.secondary)
                        Text(formattedDuration(duration))
                    }
                }
                GridRow {
                    Label("Application", systemImage: "app.badge")
                        .foregroundStyle(.secondary)
                    Text(meeting.meetingApplication)
                }
            }
            .font(.callout)
        }
    }

    // MARK: - Audio Player

    private var audioPlayerSection: some View {
        VStack(spacing: 12) {
            // Progress bar
            Slider(
                value: $player.currentTime,
                in: 0...(player.duration > 0 ? player.duration : 1),
                onEditingChanged: { editing in
                    if !editing { player.seek(to: player.currentTime) }
                }
            )
            .tint(.accentColor)

            HStack {
                Text(timeString(player.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeString(player.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Spacer()

                // Rewind 10s
                Button {
                    player.seek(to: max(0, player.currentTime - 10))
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])

                // Play / Pause
                Button {
                    player.isPlaying ? player.pause() : player.play()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                // Forward 10s
                Button {
                    player.seek(to: min(player.duration, player.currentTime + 10))
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: [])

                Spacer()

                // Speed picker
                Menu(player.speedLabel) {
                    ForEach(AudioPlayerViewModel.speeds, id: \.self) { speed in
                        Button("\(speed, specifier: "%.2g")×") {
                            player.setSpeed(speed)
                        }
                    }
                }
                .frame(width: 60)
                .menuStyle(.borderlessButton)
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()

                switch meeting.transcriptionStatus {
                case .pending:
                    Button("Transcribe") { onRetry(meeting) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .failed:
                    Button("Retry") { onRetry(meeting) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                default:
                    EmptyView()
                }

                Toggle(isOn: $showRawMarkdown) {
                    Text("Raw")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }

            switch meeting.transcriptionStatus {
            case .pending:
                Label("Press Transcribe to generate a transcript", systemImage: "waveform.and.mic")
                    .foregroundStyle(.secondary)

            case .processing:
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Transcribing…")
                        .foregroundStyle(.secondary)
                }

            case .failed(let msg):
                VStack(alignment: .leading) {
                    Label("Transcription failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if !msg.isEmpty {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }

            case .completed:
                if transcriptContent.isEmpty {
                    Text("No transcript content found.")
                        .foregroundStyle(.secondary)
                } else {
                    let filtered = filteredTranscript
                    if showRawMarkdown {
                        ScrollView {
                            Text(filtered)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(LocalizedStringKey(filtered))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.recordingURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button(role: .destructive) {
                onDelete(meeting)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
    }

    // MARK: - Transcript loading

    private func loadTranscript() {
        guard let url = meeting.transcriptURL else { return }
        transcriptContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private var filteredTranscript: String {
        guard !searchText.isEmpty else { return transcriptContent }
        return transcriptContent.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains(searchText) }
            .joined(separator: "\n")
    }

    // MARK: - Formatters

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        return f.string(from: date)
    }

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func formattedDuration(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600; let m = (Int(s) % 3600) / 60; let sec = Int(s) % 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }

    private func timeString(_ s: TimeInterval) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Empty state

struct MeetingDetailEmptyView: View {
    var body: some View {
        ContentUnavailableView(
            "No Meeting Selected",
            systemImage: "waveform",
            description: Text("Select a meeting from the list to view its details.")
        )
    }
}
