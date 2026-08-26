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

    @State private var sidebarFilter: SidebarFilter = .allMeetings
    @State private var selectedMeeting: Meeting?

    // MARK: - Helpers

    private func reloadAndSync() async {
        await repo.reload()
        // Refresh selectedMeeting so the detail view reflects updated status/transcript
        if let current = selectedMeeting {
            selectedMeeting = repo.meetings.first { $0.id == current.id }
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarFilter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            MeetingListView(
                groups: repo.grouped(by: sidebarFilter),
                selection: $selectedMeeting
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetailView(
                    meeting: meeting,
                    onDelete: { m in
                        repo.delete(m)
                        selectedMeeting = nil
                    },
                    onRetry: { m in
                        Task {
                            await repo.retryTranscription(m)
                            await reloadAndSync()
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
                Task { await reloadAndSync() }
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
