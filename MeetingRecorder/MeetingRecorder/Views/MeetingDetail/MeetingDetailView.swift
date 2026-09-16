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
    var folderRepo: FolderRepository
    let onDelete: (Meeting) -> Void
    let onRetry:  (Meeting) -> Void
    let onMoveToFolder: (Meeting, UUID?) -> Void
    let onRename: (Meeting) -> Void

    @StateObject private var player = AudioPlayerViewModel()
    @State private var showRawMarkdown = false
    @State private var searchText = ""
    @State private var transcriptContent: String = ""
    @State private var showFolderPicker = false
    @State private var transcriptionProgress: Double = 0
    @State private var transcriptionProgressLabel: String = "Transcribing…"
    @State private var isTranscribing: Bool = false

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
        .toolbar { toolbarItems }
        .task(id: meeting.id) {
            while !Task.isCancelled {
                let job = await TranscriptionQueue.shared.job(for: meeting.id)
                if let job {
                    if case .processing = job.status {
                        isTranscribing = true
                        transcriptionProgress = job.progress
                        transcriptionProgressLabel = job.progressLabel.isEmpty ? "Transcribing…" : job.progressLabel
                    } else {
                        isTranscribing = false
                    }
                } else {
                    // No job in queue — reset
                    isTranscribing = false
                    transcriptionProgress = 0
                    transcriptionProgressLabel = "Transcribing…"
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        .onAppear {
            player.load(url: meeting.recordingURL)
            loadTranscript()
        }
        .onChange(of: meeting) { old, new in
            // Reload player only when switching to a different recording
            if old.recordingURL != new.recordingURL {
                player.load(url: new.recordingURL)
            }
            // Always reload transcript content — status or URL may have changed
            loadTranscript()
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showFolderPicker) {
            MoveFolderSheetView(
                meeting: meeting,
                folderRepo: folderRepo,
                onMove: { folderID in
                    onMoveToFolder(meeting, folderID)
                    showFolderPicker = false
                },
                onCancel: { showFolderPicker = false }
            )
        }
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
                    player.isScrubbing = editing
                    if !editing {
                        player.seek(to: player.currentTime)
                    }
                }
            )
            .tint(.accentColor)
            .disabled(!player.isLoaded)

            HStack {
                Text(timeString(player.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if player.isLoaded {
                    Text(timeString(player.duration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().scaleEffect(0.5)
                }
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

                // Inline search — avoids .searchable toolbar conflict with MeetingListView
                TextField("Search transcript…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                if isTranscribing {
                    EmptyView()
                } else {
                    switch meeting.transcriptionStatus {
                    case .pending:
                        Button("Transcribe") { onRetry(meeting) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    case .completed:
                        Button("Re-transcribe") { onRetry(meeting) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    case .failed:
                        Button("Retry") { onRetry(meeting) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    case .processing:
                        EmptyView()
                    }
                }

                Toggle(isOn: $showRawMarkdown) {
                    Text("Raw")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }

            if isTranscribing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: transcriptionProgress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(transcriptionProgressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(transcriptionProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                switch meeting.transcriptionStatus {
                case .pending:
                    Label("Press Transcribe to generate a transcript", systemImage: "waveform.and.mic")
                        .foregroundStyle(.secondary)

                case .processing:
                    // Covered by isTranscribing above; shown here as fallback
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Transcribing…").foregroundStyle(.secondary)
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
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                onRename(meeting)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                showFolderPicker = true
            } label: {
                Label("Move to Folder", systemImage: "folder.badge.gear")
            }

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
            "No Recording Selected",
            systemImage: "waveform",
            description: Text("Select a recording from the list to view its details.")
        )
    }
}

// MARK: - Move to Folder sheet

private struct MoveFolderSheetView: View {
    let meeting: Meeting
    var folderRepo: FolderRepository
    let onMove: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move to Folder")
                .font(.headline)

            List {
                Button {
                    onMove(nil)
                } label: {
                    Label("No Folder", systemImage: "tray")
                }
                .buttonStyle(.plain)
                .foregroundStyle(meeting.folderID == nil ? Color.accentColor : Color.primary)

                ForEach(flatFolders(folderRepo.folders, depth: 0)) { item in
                    Button {
                        onMove(item.folder.id)
                    } label: {
                        HStack {
                            Text(String(repeating: "    ", count: item.depth))
                                + Text(Image(systemName: "folder"))
                                + Text(" \(item.folder.name)")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(meeting.folderID == item.folder.id ? Color.accentColor : Color.primary)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 280, minHeight: 240)
    }

    private struct FlatFolderItem: Identifiable {
        let id: UUID
        let folder: Folder
        let depth: Int
    }

    private func flatFolders(_ folders: [Folder], depth: Int) -> [FlatFolderItem] {
        var result: [FlatFolderItem] = []
        for f in folders {
            result.append(FlatFolderItem(id: f.id, folder: f, depth: depth))
            result += flatFolders(f.children, depth: depth + 1)
        }
        return result
    }
}
