//
//  MeetingListView.swift
//  MeetingRecorder
//
//  Middle column: meetings grouped by date, sorted newest-first.
//

import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {

    let groups: [MeetingDateGroup]
    @Binding var selection: Meeting?
    let onDelete: ([Meeting]) -> Void
    let onRename: (Meeting) -> Void

    @State private var isSelecting: Bool = false
    @State private var multiSelection: Set<Meeting> = []

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform.slash",
                    description: Text("Recordings will appear here after you stop recording.")
                )
            } else {
                if isSelecting {
                    List(selection: $multiSelection) {
                        ForEach(groups) { group in
                            Section(group.label) {
                                ForEach(group.meetings) { meeting in
                                    MeetingRowView(meeting: meeting).tag(meeting)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                } else {
                    List(selection: $selection) {
                        ForEach(groups) { group in
                            Section(group.label) {
                                ForEach(group.meetings) { meeting in
                                    MeetingRowView(meeting: meeting)
                                        .tag(meeting)
                                        .contextMenu {
                                            Button("Rename") { onRename(meeting) }
                                            Button("Delete", role: .destructive) { onDelete([meeting]) }
                                        }
                                        .onDrag {
                                            NSItemProvider(object: meeting.id.uuidString as NSString)
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle("Recordings")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        onDelete(Array(multiSelection))
                        multiSelection = []
                        isSelecting = false
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .disabled(multiSelection.isEmpty)
                    .tint(.red)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        multiSelection = []
                        isSelecting = false
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Select") {
                        isSelecting = true
                        selection = nil
                    }
                    .disabled(groups.isEmpty)
                }
            }
        }
    }
}

// MARK: - Row

struct MeetingRowView: View {

    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusIndicator
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(meeting.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if !meeting.recordingFileExists {
                        Text("File missing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    Text(timeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let duration = meeting.duration, duration > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(durationString(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(meeting.meetingApplication)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if !meeting.recordingFileExists {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help("Recording file is missing")
                .accessibilityLabel("Recording file missing")
        } else {
            Text(statusSymbol)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(statusColor)
        }
    }

    private var statusSymbol: String {
        switch meeting.transcriptionStatus {
        case .pending:    return "○"
        case .processing: return "◌"
        case .completed:  return "✓"
        case .failed:     return "!"
        }
    }

    private var statusColor: Color {
        switch meeting.transcriptionStatus {
        case .pending:    return .secondary
        case .processing: return .blue
        case .completed:  return .green
        case .failed:     return .orange
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: meeting.startedAt)
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
