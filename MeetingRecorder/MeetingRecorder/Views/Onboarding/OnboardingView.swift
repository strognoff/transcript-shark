//
//  OnboardingView.swift
//  MeetingRecorder
//
//  Milestone 10 — Multi-step first-run onboarding sheet.
//  Shown once via the "onboardingCompleted" UserDefaults key.
//

import SwiftUI
import AVFoundation
import UserNotifications

// MARK: - Onboarding Step

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case screenRecording
    case microphone
    case notifications
    case consent
}

// MARK: - OnboardingView

struct OnboardingView: View {

    @State private var currentStep: OnboardingStep = .welcome
    @State private var consentChecked: Bool = false

    // Permission states
    @State private var screenRecordingGranted: Bool = false
    @State private var microphoneGranted: Bool = false
    @State private var notificationsGranted: Bool = false

    // Called when onboarding is complete
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressDots
                .padding(.top, 32)
                .padding(.bottom, 8)

            // Step content
            Group {
                switch currentStep {
                case .welcome:       welcomeStep
                case .screenRecording: screenRecordingStep
                case .microphone:    microphoneStep
                case .notifications: notificationsStep
                case .consent:       consentStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)

            // Navigation
            navigationRow
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
        .frame(width: 520, height: 440)
        .onAppear { refreshPermissionStates() }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut, value: currentStep)
            }
        }
    }

    // MARK: - Navigation Row

    private var navigationRow: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation { goBack() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
            primaryButton
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch currentStep {
        case .welcome:
            Button("Get Started") { withAnimation { advance() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

        case .screenRecording:
            if screenRecordingGranted {
                Button("Continue") { withAnimation { advance() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Grant Permission") { openScreenRecordingSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

        case .microphone:
            if microphoneGranted {
                Button("Continue") { withAnimation { advance() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Grant Permission") { requestMicrophoneAccess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

        case .notifications:
            if notificationsGranted {
                Button("Continue") { withAnimation { advance() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Enable Notifications") { requestNotificationAccess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

        case .consent:
            Button("Start Using Meeting Recorder") {
                completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!consentChecked)
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)

            VStack(spacing: 8) {
                Text("Meeting Recorder")
                    .font(.largeTitle.bold())
                Text("Automatically record, transcribe, and organise your meetings — privately, on your Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 20)
    }

    private var screenRecordingStep: some View {
        permissionStep(
            icon: "desktopcomputer",
            iconColor: .blue,
            title: "Screen Recording",
            description: "Meeting Recorder needs Screen Recording permission to capture system audio from your meetings — including remote participants. No video is ever recorded.",
            isGranted: screenRecordingGranted
        )
        .onAppear {
            // Poll for permission grant while this step is visible
            startPollingScreenRecording()
        }
    }

    private var microphoneStep: some View {
        permissionStep(
            icon: "mic.fill",
            iconColor: .orange,
            title: "Microphone Access",
            description: "Meeting Recorder uses your microphone to capture your voice during recordings, so both sides of the conversation are preserved.",
            isGranted: microphoneGranted
        )
    }

    private var notificationsStep: some View {
        permissionStep(
            icon: "bell.fill",
            iconColor: .purple,
            title: "Notifications",
            description: "Get notified when a recording starts or stops, and when transcription is complete.",
            isGranted: notificationsGranted
        )
    }

    private var consentStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 50))
                .foregroundStyle(.yellow)

            VStack(spacing: 8) {
                Text("Recording Consent")
                    .font(.title2.bold())
                Text("Before using Meeting Recorder, please confirm that you understand your responsibilities.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $consentChecked) {
                Text("I understand that I am responsible for obtaining consent from all meeting participants before recording, in accordance with applicable laws and workplace policies.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 8)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Reusable Permission Step

    private func permissionStep(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        isGranted: Bool
    ) -> some View {
        VStack(spacing: 20) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 50))
                    .foregroundStyle(iconColor)
                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                        .background(Color.white.clipShape(Circle()))
                        .offset(x: 8, y: 8)
                }
            }
            .frame(height: 64)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())

                if isGranted {
                    Label("Permission granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Navigation

    private func advance() {
        guard let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        refreshPermissionStates()
    }

    private func goBack() {
        guard let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    // MARK: - Permission Handling

    private func refreshPermissionStates() {
        // Screen recording: no direct API — check via CGWindowListCopyWindowInfo
        screenRecordingGranted = checkScreenRecordingPermission()

        // Microphone
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = audioStatus == .authorized

        // Notifications
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationsGranted = settings.authorizationStatus == .authorized
            }
        }
    }

    private func checkScreenRecordingPermission() -> Bool {
        // CGWindowListCopyWindowInfo returns window names only when screen recording is granted.
        // An empty list (or list without ownerName for windows owned by other apps) means denied.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        // If we can see at least one window that belongs to a process other than our own,
        // screen recording permission is granted.
        let ourPID = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return pid != ourPID
        }
    }

    private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
        // Poll until the user returns
        startPollingScreenRecording()
    }

    private func startPollingScreenRecording() {
        Task {
            for _ in 0..<60 {   // poll for up to ~60s
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let granted = checkScreenRecordingPermission()
                await MainActor.run { screenRecordingGranted = granted }
                if granted { break }
            }
        }
    }

    private func requestMicrophoneAccess() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run { microphoneGranted = granted }
            if granted { withAnimation { advance() } }
        }
    }

    private func requestNotificationAccess() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                await MainActor.run { notificationsGranted = granted }
                if granted { withAnimation { advance() } }
            } catch {
                // Permission denied or restricted — let user continue anyway
                await MainActor.run { withAnimation { advance() } }
            }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onComplete()
    }
}

#Preview {
    OnboardingView { }
}
