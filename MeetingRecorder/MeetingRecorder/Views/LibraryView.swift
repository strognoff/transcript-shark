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
                        Task { await repo.retryTranscription(m) }
                    }
                )
            } else {
                MeetingDetailEmptyView()
            }
        }
        .onAppear { repo.load() }
        // Reload when a new recording finishes
        .onChange(of: appState.recorderState) { _, newState in
            if case .finished = newState {
                Task { await repo.reload() }
            }
        }
        // Reload when transcription completes (poll every 3s while a job is processing)
        .task {
            while true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let jobs = await TranscriptionQueue.shared.allJobs()
                let hasActive = jobs.contains {
                    if case .processing = $0.status { return true }
                    if case .pending = $0.status { return true }
                    return false
                }
                if hasActive { await repo.reload() }
            }
        }
    }
}
