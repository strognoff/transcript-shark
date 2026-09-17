//
//  SummaryPanelView.swift
//  MeetingRecorder
//
//  Right-side "4th panel" — on-demand AI summary powered by the configured local AI CLI.
//  Summaries are persisted next to recordings; prompt overrides are stored per recording.
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
    /// Optional per-recording prompt override. Blank values fall back to the global prompt.
    let promptOverride: String?
    /// Persists prompt override changes for this recording.
    let onPromptOverrideChange: (String?) -> Void

    @State private var state: SummaryState = .idle
    @State private var summaryElapsed: TimeInterval = 0
    @State private var isPromptEditorExpanded = false
    @State private var promptDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            promptOverrideEditor
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            promptDraft = promptOverride ?? ""
            loadPersistedSummaryIfNeeded()
        }
        .onChange(of: recordingURL) { _, _ in
            // Switching to a different meeting — try to load its persisted summary
            state = .idle
            promptDraft = promptOverride ?? ""
            loadPersistedSummaryIfNeeded()
        }
        .onChange(of: promptOverride) { _, newValue in
            promptDraft = newValue ?? ""
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

    // MARK: - Prompt override

    private var promptOverrideEditor: some View {
        DisclosureGroup(isExpanded: $isPromptEditorExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom instructions saved here override the global AI Summary prompt for this recording only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $promptDraft)
                    .font(.callout)
                    .frame(minHeight: 92)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )

                HStack(spacing: 8) {
                    Button("Save Override") {
                        savePromptOverride()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!hasPromptDraftChanged)

                    Button("Use Global Prompt") {
                        promptDraft = ""
                        onPromptOverrideChange(nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled((promptOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Prompt Override")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(hasSavedPromptOverride ? "Custom" : "Global")
                    .font(.caption)
                    .foregroundStyle(hasSavedPromptOverride ? .purple : .secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var hasSavedPromptOverride: Bool {
        !(promptOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPromptDraftChanged: Bool {
        promptDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (promptOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func savePromptOverride() {
        let trimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onPromptOverrideChange(trimmed.isEmpty ? nil : trimmed)
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

            Text("Generate a summary using the prompt for this recording, or the global AI Summary instructions from Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Button("Summarise") {
                startSummary()
            }
            .buttonStyle(.borderedProminent)
            .disabled(transcriptContent.isEmpty)
            .help(transcriptContent.isEmpty ? "Transcribe this recording first" : "Generate AI summary using the selected provider")
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
            Text(elapsedLabel(summaryElapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .task {
            summaryElapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                summaryElapsed += 1
            }
        }
    }

    private func elapsedLabel(_ elapsed: TimeInterval) -> String {
        let s = Int(elapsed)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
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
        if hasPromptDraftChanged {
            savePromptOverride()
        }

        state = .loading
        let transcript = transcriptContent
        let url = recordingURL
        let override = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let summary = try await TabnineSummaryService.shared.summarise(
                    transcript: transcript,
                    recordingURL: url,
                    promptOverride: override.isEmpty ? nil : override
                )
                state = .done(summary)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
