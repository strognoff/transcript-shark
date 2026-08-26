//
//  MeetingListView.swift
//  MeetingRecorder
//
//  Middle column: meetings grouped by date, sorted newest-first.
//

import SwiftUI

struct MeetingListView: View {

    let groups: [MeetingDateGroup]
    @Binding var selection: Meeting?

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform.slash",
                    description: Text("Recordings will appear here after you stop a meeting.")
                )
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section(group.label) {
                            ForEach(group.meetings) { meeting in
                                MeetingRowView(meeting: meeting)
                                    .tag(meeting)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Meetings")
    }
}

// MARK: - Row

struct MeetingRowView: View {

    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Text(statusSymbol)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

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
