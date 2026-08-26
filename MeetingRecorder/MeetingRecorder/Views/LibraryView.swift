//
//  LibraryView.swift
//  MeetingRecorder
//
//  Three-column NavigationSplitView — the main app window for Milestone 5+.
//

import SwiftUI

struct LibraryView: View {

    @EnvironmentObject private var appState: AppState
    @State private var repo = MeetingRepository()
    @State private var folderRepo = FolderRepository()

    @State private var sidebarFilter: SidebarFilter = .allMeetings
    @State private var selectedMeeting: Meeting?
    @State private var searchText: String = ""

    // MARK: - Helpers

    /// Returns filtered + grouped meetings, applying the sidebar filter and search text.
    private var filteredGroups: [MeetingDateGroup] {
        let baseGroups = repo.grouped(by: sidebarFilter, allFolders: folderRepo.folders)
        guard !searchText.isEmpty else { return baseGroups }
        return baseGroups.compactMap { group in
            let filtered = group.meetings.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
            guard !filtered.isEmpty else { return nil }
            return MeetingDateGroup(id: group.id, label: group.label, meetings: filtered)
        }
    }

    private func reloadAndSync() async {
        folderRepo.reload()
        await repo.reload()
        // Refresh selectedMeeting so the detail view reflects updated status/transcript
        if let current = selectedMeeting {
            selectedMeeting = repo.meetings.first { $0.id == current.id }
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarFilter, folderRepo: folderRepo, meetingRepo: repo)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            MeetingListView(
                groups: filteredGroups,
                selection: $selectedMeeting
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search meetings")
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetailView(
                    meeting: meeting,
                    folderRepo: folderRepo,
                    onDelete: { m in
                        repo.delete(m)
                        selectedMeeting = nil
                    },
                    onRetry: { m in
                        Task {
                            await repo.retryTranscription(m)
                            await reloadAndSync()
                        }
                    },
                    onMoveToFolder: { m, folderID in
                        repo.move(m, toFolder: folderID)
                        if let idx = repo.meetings.firstIndex(where: { $0.id == m.id }) {
                            selectedMeeting = repo.meetings[idx]
                        }
                    }
                )
            } else {
                MeetingDetailEmptyView()
            }
        }
        .onAppear {
            Task { await reloadAndSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionJobCompleted)) { _ in
            Task { await reloadAndSync() }
        }
        .onChange(of: appState.recorderState) { _, newState in
            if case .finished = newState {
                Task {
                    // SCRecordingOutput needs a moment to flush the MP4 after
                    // stopCapture() returns — wait 1s before scanning disk
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await reloadAndSync()
                }
            }
        }
        // Poll every 2s while transcription is active, refresh selected meeting when done
        .task {
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let jobs = await TranscriptionQueue.shared.allJobs()
                let hasActive = jobs.contains {
                    if case .processing = $0.status { return true }
                    if case .pending = $0.status { return true }
                    return false
                }
                if hasActive {
                    await reloadAndSync()
                }
            }
        }
    }
}
