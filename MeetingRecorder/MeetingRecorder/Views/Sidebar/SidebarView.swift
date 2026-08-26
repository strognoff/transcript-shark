//
//  SidebarView.swift
//  MeetingRecorder
//
//  Left column: Library section + Folders placeholder.
//

import SwiftUI

struct SidebarView: View {

    @Binding var selection: SidebarFilter

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Meetings", systemImage: "tray.full")
                    .tag(SidebarFilter.allMeetings)
                Label("Today", systemImage: "sun.max")
                    .tag(SidebarFilter.today)
                Label("This Week", systemImage: "calendar")
                    .tag(SidebarFilter.thisWeek)
            }

            Section("Folders") {
                Label("No folders yet", systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .disabled(true)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Meeting Recorder")
    }
}
