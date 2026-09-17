//
//  SettingsView.swift
//  MeetingRecorder
//
//  Milestone 10 — Settings window with General, Recording, Transcription,
//  Storage, and Privacy tabs.
//

import SwiftUI
import ServiceManagement
import Speech
import UserNotifications

// MARK: - SettingsView

private enum SettingsTab: String, CaseIterable {
    case general       = "General"
    case recording     = "Recording"
    case transcription = "Transcription"
    case storage       = "Storage"
    case privacy       = "Privacy"
    case aiSummary     = "AI Summary"

    var icon: String {
        switch self {
        case .general:       return "gearshape"
        case .recording:     return "record.circle"
        case .transcription: return "text.bubble"
        case .storage:       return "externaldrive"
        case .privacy:       return "hand.raised.fill"
        case .aiSummary:     return "sparkles"
        }
    }
}

struct SettingsView: View {

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar-style tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                            Text(tab.rawValue)
                                .font(.caption)
                        }
                        .frame(width: 72, height: 52)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .general:       GeneralSettingsTab()
                case .recording:     RecordingSettingsTab()
                case .transcription: TranscriptionSettingsTab()
                case .storage:       StorageSettingsTab()
                case .privacy:       PrivacySettingsTab()
                case .aiSummary:     AISummarySettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 440)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {

    @State private var launchAtLoginEnabled: Bool = SMAppService.mainApp.status == .enabled
    @State private var notificationsEnabled: Bool = false
    @AppStorage("autoRecordingEnabled") private var autoRecordingEnabledStorage: Bool = true
    @AppStorage("onboardingCompleted") private var onboardingCompleted: Bool = false

    var body: some View {
        Form {
            Section("App Behaviour") {
                Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }

                LabeledContent("Show in Menu Bar") {
                    Text("Always on")
                        .foregroundStyle(.secondary)
                }

                Toggle("Auto-Recording Enabled", isOn: Binding(
                    get: { AppState.shared.autoRecordingEnabled },
                    set: { AppState.shared.autoRecordingEnabled = $0 }
                ))
                .help("Automatically start recording when a supported communication application is detected.")

                Toggle("Show startup screen at launch", isOn: Binding(
                    get: { !onboardingCompleted },
                    set: { onboardingCompleted = !$0 }
                ))
                .help("When enabled, the welcome screen is shown every time the app launches.")

                Toggle("Show Notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, newValue in
                        if newValue { requestNotifications() }
                    }
                    .task { await refreshNotificationStatus() }
            }
        }
        .formStyle(.grouped)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { await refreshNotificationStatus() }
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsEnabled = settings.authorizationStatus == .authorized
    }
}

// MARK: - Recording Tab

private struct RecordingSettingsTab: View {

    @ObservedObject private var appState = AppState.shared

    var body: some View {
        Form {
            Section("Microphone") {
                LabeledContent("Microphone") {
                    Text("System Default")
                        .foregroundStyle(.secondary)
                }
                Text("Transcript Shark uses the system default microphone. Change it in System Settings → Sound → Input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Capture Area") {
                Picker("Record", selection: Binding(
                    get: { appState.captureMode },
                    set: { appState.setCaptureMode($0) }
                )) {
                    ForEach(RecordingCaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose whether new recordings capture the whole screen or one selected window.")

                if appState.captureMode == .selectedWindow {
                    Picker("Window", selection: Binding(
                        get: { appState.selectedCaptureWindowID ?? "" },
                        set: { appState.setSelectedCaptureWindowID($0.isEmpty ? nil : $0) }
                    )) {
                        Text("Choose a window").tag("")
                        ForEach(appState.availableCaptureWindows) { window in
                            Text(window.displayName).tag(window.id)
                        }
                    }
                    .disabled(appState.availableCaptureWindows.isEmpty)

                    Button {
                        Task { @MainActor in
                            await appState.refreshAvailableCaptureWindows()
                        }
                    } label: {
                        Label("Refresh Windows", systemImage: "arrow.clockwise")
                    }

                    Text("If the selected window is unavailable when recording starts, Transcript Shark records the whole screen. When the camera bubble is on, it stays inside the selected window while that window is available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Camera Bubble") {
                Toggle("Show camera bubble", isOn: Binding(
                    get: { appState.cameraBubbleEnabled },
                    set: { newValue in
                        Task { @MainActor in
                            await appState.setCameraBubbleEnabled(newValue)
                        }
                    }
                ))
                .help("Manually show a circular camera preview in the bottom-right corner of the screen.")

                Picker("Camera", selection: Binding(
                    get: { appState.selectedCameraID ?? "" },
                    set: { newValue in
                        appState.setSelectedCameraID(newValue.isEmpty ? nil : newValue)
                    }
                )) {
                    Text("Automatic").tag("")
                    ForEach(appState.availableCameras) { camera in
                        Text(camera.localizedName).tag(camera.id)
                    }
                }
                .disabled(appState.availableCameras.isEmpty)
                .help("Choose which camera is used by the camera bubble. Select your USB camera here.")
            }

            Section("Audio Quality") {
                LabeledContent("Quality") {
                    Text("System Default (AAC)")
                        .foregroundStyle(.secondary)
                }
                Text("Recordings are saved as MP4 files with system-managed audio quality.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshAvailableCameras()
            Task { @MainActor in
                await appState.refreshAvailableCaptureWindows()
            }
        }
    }
}

// MARK: - Transcription Tab

private struct TranscriptionSettingsTab: View {

    @AppStorage("autoTranscribe") private var autoTranscribe: Bool = false
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = Locale.current.identifier

    private let commonLocales: [Locale] = [
        Locale(identifier: "en_US"),
        Locale(identifier: "en_GB"),
        Locale(identifier: "pt_BR"),
        Locale(identifier: "es_ES"),
        Locale(identifier: "fr_FR"),
        Locale(identifier: "de_DE")
    ]

    var body: some View {
        Form {
            Section("Transcription") {
                Toggle("Auto-transcribe after recording", isOn: $autoTranscribe)
                    .help("Automatically begin transcription when a recording finishes. Off by default — use the Retry button in Recording Detail.")

                Picker("Language", selection: $transcriptionLanguage) {
                    ForEach(commonLocales, id: \.identifier) { locale in
                        Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                .pickerStyle(.menu)
                Text("Select the primary language spoken in your recordings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Engine") {
                LabeledContent("Speech Engine") {
                    Text("Apple Speech")
                        .foregroundStyle(.secondary)
                }
                Text("Transcription runs on-device when possible using Apple's Speech framework.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage Tab

private struct StorageSettingsTab: View {

    @AppStorage("retentionPolicyDays") private var retentionPolicyDays: Int = 0

    private var recordingsURL: URL { PersistenceController.baseURL.appendingPathComponent("Recordings") }

    var body: some View {
        Form {
            Section("Storage Location") {
                LabeledContent("Recordings Folder") {
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(recordingsURL)
                    }
                }
                Text(recordingsURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Retention") {
                Picker("Delete recordings after", selection: $retentionPolicyDays) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.menu)
                Text("Automatic deletion is not yet implemented; this setting is reserved for a future release.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy Tab

private struct PrivacySettingsTab: View {

    @State private var screenRecordingGranted: Bool = false
    @State private var microphoneGranted: Bool = false
    @State private var cameraGranted: Bool = false

    var body: some View {
        Form {
            Section("Data Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Local Only", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("All recordings and transcripts are stored locally on your Mac. Nothing is uploaded to any server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Screen Recording",
                    icon: "desktopcomputer",
                    isGranted: screenRecordingGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )

                permissionRow(
                    title: "Microphone",
                    icon: "mic.fill",
                    isGranted: microphoneGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )

                permissionRow(
                    title: "Camera",
                    icon: "camera.fill",
                    isGranted: cameraGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
    }

    private func permissionRow(title: String, icon: String, isGranted: Bool, settingsURL: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open Settings") {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func refreshPermissions() {
        // Microphone
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = audioStatus == .authorized

        // Camera
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        cameraGranted = cameraStatus == .authorized

        // Screen recording (heuristic — same as OnboardingView)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ourPID = ProcessInfo.processInfo.processIdentifier
        screenRecordingGranted = windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return pid != ourPID
        }
    }
}

// MARK: - AI Summary Tab

private struct AISummarySettingsTab: View {

    @AppStorage(kAISummaryProviderKey) private var selectedProviderRawValue: String = AISummaryProvider.tabnine.rawValue
    @AppStorage(kTabnineCLIPathKey) private var tabnineCLIPath: String = ""
    @AppStorage(kOpenCodeCLIPathKey) private var openCodeCLIPath: String = ""
    @AppStorage(kTabnineSummaryPromptKey) private var summaryPrompt: String = ""

    private var selectedProvider: AISummaryProvider {
        AISummaryProvider.resolved(from: selectedProviderRawValue)
    }

    private var resolvedPath: String {
        executablePath(for: selectedProvider)
    }

    private var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: resolvedPath)
    }

    private var effectiveSummaryPrompt: Binding<String> {
        Binding(
            get: { summaryPrompt.isEmpty ? kDefaultTabnineSummaryPrompt : summaryPrompt },
            set: { summaryPrompt = $0 }
        )
    }

    private var isUsingDefaultPrompt: Bool {
        summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("AI Provider", selection: $selectedProviderRawValue) {
                    ForEach(AISummaryProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Executable Path") {
                    HStack(spacing: 8) {
                        TextField(selectedProvider.defaultExecutablePath, text: executablePathBinding(for: selectedProvider))
                            .textFieldStyle(.roundedBorder)
                            .help("Path to the \(selectedProvider.displayName) CLI binary. Leave empty to use the default.")

                        Button("Browse…") {
                            browseForExecutable(provider: selectedProvider)
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Status") {
                    if binaryExists {
                        Label("Found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)

                if !binaryExists {
                    Text("The \(selectedProvider.displayName) CLI was not found at the specified path. Install \(selectedProvider.displayName) or update the path above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Summary Instructions") {
                TextEditor(text: effectiveSummaryPrompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .help("These instructions are sent to \(selectedProvider.displayName) when generating or re-generating an AI Summary.")

                HStack {
                    Text(isUsingDefaultPrompt ? "Using the default prompt." : "Using a custom prompt.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") {
                        summaryPrompt = ""
                    }
                    .disabled(isUsingDefaultPrompt)
                }

                Text("Example: “Give me only the highlights.”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("The AI Summary panel uses your selected local AI CLI provider to summarise recording transcripts. No data is sent by Transcript Shark to its own servers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func executablePath(for provider: AISummaryProvider) -> String {
        switch provider {
        case .tabnine:
            return tabnineCLIPath.isEmpty ? provider.defaultExecutablePath : tabnineCLIPath
        case .openCode:
            return openCodeCLIPath.isEmpty ? provider.defaultExecutablePath : openCodeCLIPath
        }
    }

    private func executablePathBinding(for provider: AISummaryProvider) -> Binding<String> {
        switch provider {
        case .tabnine:
            return $tabnineCLIPath
        case .openCode:
            return $openCodeCLIPath
        }
    }

    private func browseForExecutable(provider: AISummaryProvider) {
        let panel = NSOpenPanel()
        panel.title = "Select \(provider.displayName) Executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(provider.displayName) CLI binary"
        if panel.runModal() == .OK, let url = panel.url {
            switch provider {
            case .tabnine:
                tabnineCLIPath = url.path
            case .openCode:
                openCodeCLIPath = url.path
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
