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

struct SettingsView: View {

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }

            TranscriptionSettingsTab()
                .tabItem { Label("Transcription", systemImage: "text.bubble") }

            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "externaldrive") }

            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "hand.raised.fill") }
        }
        .frame(width: 520, height: 400)
        .padding(20)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {

    @State private var launchAtLoginEnabled: Bool = SMAppService.mainApp.status == .enabled
    @State private var notificationsEnabled: Bool = false
    @AppStorage("autoRecordingEnabled") private var autoRecordingEnabledStorage: Bool = true

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
                .help("Automatically start recording when a supported meeting application is detected.")

                Toggle("Enable Notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, newValue in
                        handleNotificationToggle(newValue)
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
            // Revert toggle on failure
            launchAtLoginEnabled = !enabled
        }
    }

    private func handleNotificationToggle(_ enabled: Bool) {
        if enabled {
            Task {
                do {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound, .badge]
                    )
                    await MainActor.run { notificationsEnabled = granted }
                } catch {
                    await MainActor.run { notificationsEnabled = false }
                }
            }
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsEnabled = settings.authorizationStatus == .authorized
    }
}

// MARK: - Recording Tab

private struct RecordingSettingsTab: View {

    var body: some View {
        Form {
            Section("Microphone") {
                LabeledContent("Microphone") {
                    Text("System Default")
                        .foregroundStyle(.secondary)
                }
                Text("Meeting Recorder uses the system default microphone. Change it in System Settings → Sound → Input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Audio Quality") {
                LabeledContent("Quality") {
                    Text("System Default (AAC)")
                        .foregroundStyle(.secondary)
                }
                Text("Audio quality is determined by ScreenCaptureKit and cannot be customised independently.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription Tab

private struct TranscriptionSettingsTab: View {

    @AppStorage("autoTranscribe") private var autoTranscribe: Bool = false
    @AppStorage("transcriptionLocale") private var transcriptionLocale: String = Locale.current.identifier

    private var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted { localeDisplayName($0) < localeDisplayName($1) }
    }

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Auto-transcribe after recording", isOn: $autoTranscribe)
                    .help("Automatically begin transcription when a recording finishes. Off by default — use the Retry button in Meeting Detail.")
            }

            Section("Language") {
                Picker("Language", selection: $transcriptionLocale) {
                    ForEach(supportedLocales, id: \.identifier) { locale in
                        Text(localeDisplayName(locale))
                            .tag(locale.identifier)
                    }
                }
                .pickerStyle(.menu)
                Text("Select the primary language spoken in your meetings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func localeDisplayName(_ locale: Locale) -> String {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
        return name
    }
}

// MARK: - Storage Tab

private struct StorageSettingsTab: View {

    @AppStorage("retentionDays") private var retentionDays: Int = 0
    @State private var storageUsedBytes: Int64 = 0

    private let recordingsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MeetingRecorder/Recordings", isDirectory: true)
    }()

    private let retentionOptions: [(label: String, days: Int)] = [
        ("Never", 0),
        ("30 days", 30),
        ("60 days", 60),
        ("90 days", 90),
    ]

    var body: some View {
        Form {
            Section("Usage") {
                LabeledContent("Recordings Storage") {
                    Text(formattedSize(storageUsedBytes))
                        .foregroundStyle(.secondary)
                }

                Button("Open in Finder") {
                    openInFinder()
                }
            }

            Section("Retention") {
                Picker("Clean up recordings older than", selection: $retentionDays) {
                    ForEach(retentionOptions, id: \.days) { option in
                        Text(option.label).tag(option.days)
                    }
                }
                .pickerStyle(.menu)

                if retentionDays > 0 {
                    Text("Recordings older than \(retentionDays) days will be moved to the Trash on next launch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { storageUsedBytes = calculateStorageUsed() }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func calculateStorageUsed() -> Int64 {
        guard FileManager.default.fileExists(atPath: recordingsURL.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: recordingsURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let resources = try? url.resourceValues(forKeys: keys)
            if resources?.isDirectory == false {
                total += Int64(resources?.fileSize ?? 0)
            }
        }
        return total
    }

    private func openInFinder() {
        // Create directory if it doesn't exist yet
        try? FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsURL)
    }
}

// MARK: - Privacy Tab

private struct PrivacySettingsTab: View {

    @State private var screenRecordingGranted: Bool = false
    @State private var microphoneGranted: Bool = false

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
                    .font(.callout)
            } else {
                HStack(spacing: 8) {
                    Label("Not granted", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: settingsURL)!)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func refreshPermissions() {
        // Microphone
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = audioStatus == .authorized

        // Screen recording (heuristic — same as OnboardingView)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ourPID = ProcessInfo.processInfo.processIdentifier
        screenRecordingGranted = windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return pid != ourPID
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
