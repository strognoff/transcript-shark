//
//  SummaryPanelView.swift
//  MeetingRecorder
//
//  Right-side "4th panel" — on-demand AI summary powered by the local Tabnine CLI.
//  State is transient (not persisted). Clears automatically when the transcript changes.
//

import SwiftUI

// MARK: - State

private enum SummaryState {
    case idle
    case loading
    case done(String)
    case failed(String)
}

// MARK: - View

struct SummaryPanelView: View {

    /// The full plain-text transcript to summarise. Passed from the parent.
    let transcriptContent: String
    /// The recording audio file URL — used to derive the persisted summary path.
    let recordingURL: URL

    @State private var state: SummaryState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            loadPersistedSummaryIfNeeded()
        }
        .onChange(of: recordingURL) { _, _ in
            // Switching to a different meeting — try to load its persisted summary
            state = .idle
            loadPersistedSummaryIfNeeded()
        }
    }

    private func loadPersistedSummaryIfNeeded() {
        if let saved = TabnineSummaryService.shared.loadSummary(for: recordingURL) {
            state = .done(saved)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("AI Summary")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleView
        case .loading:
            loadingView
        case .done(let summary):
            doneView(summary: summary)
        case .failed(let message):
            failedView(message: message)
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.purple.opacity(0.4))

            Text("Generate a concise summary of key topics, decisions, and action items from this transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Button("Summarise") {
                startSummary()
            }
            .buttonStyle(.borderedProminent)
            .disabled(transcriptContent.isEmpty)
            .help(transcriptContent.isEmpty ? "Transcribe this meeting first" : "Generate AI summary using Tabnine")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 16)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func doneView(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(LocalizedStringKey(summary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    startSummary()
                } label: {
                    Label("Re-summarise", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Summary failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.bold())
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                startSummary()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
    }

    // MARK: - Action

    private func startSummary() {
        state = .loading
        let transcript = transcriptContent
        let url = recordingURL
        Task {
            do {
                let summary = try await TabnineSummaryService.shared.summarise(transcript: transcript, recordingURL: url)
                state = .done(summary)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
