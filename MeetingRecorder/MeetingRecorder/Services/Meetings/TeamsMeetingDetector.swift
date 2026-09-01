//
//  TeamsMeetingDetector.swift
//  MeetingRecorder
//
//  Polls NSWorkspace every 2 seconds to detect whether a Microsoft Teams
//  meeting is in progress. Emits MeetingDetectionEvents — never calls any
//  recording API directly.
//
//  Scoring (macOS 14+):
//    Teams running                    +15
//    Teams is the active app          +15
//    Microphone in use (any process)  +30  ← strong call signal
//    Teams running > 30s              +10  ← settled, not just launching
//
//  State machine:
//    IDLE → POSSIBLE_MEETING (score ≥ 35) → IN_MEETING (stable 8 s)
//    IN_MEETING → POSSIBLE_END (score < 20) → IDLE (stable 12 s)
//    POSSIBLE_END → IN_MEETING (signals return before 12 s)
//
//  Note: CGWindowList no longer returns window names on macOS 14+ without
//  Accessibility permission, so window-title heuristics are not used.
//

import AppKit
import AVFoundation
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "TeamsMeetingDetector")

// MARK: - State

private enum DetectorState {
    case idle
    case possibleMeeting
    case inMeeting
    case possibleEnd
}

// MARK: - Detector

@MainActor
final class TeamsMeetingDetector: MeetingDetector {

    // MARK: - Public callback

    var onEvent: ((MeetingDetectionEvent) -> Void)?

    // MARK: - Private

    private static let teamsBundleIDs: Set<String> = [
        "com.microsoft.teams2",
        "com.microsoft.teams"
    ]

    private var pollTimer: Timer?
    private var state: DetectorState = .idle
    private var possibleMeetingStart: Date?
    private var possibleEndStart: Date?
    private var lastKnownContext: MeetingContext?

    // MARK: - MeetingDetector

    func startMonitoring() {
        guard pollTimer == nil else { return }
        logger.info("TeamsMeetingDetector: startMonitoring")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        pollTimer?.fire()
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        state = .idle
        possibleMeetingStart = nil
        possibleEndStart = nil
        logger.info("TeamsMeetingDetector: stopMonitoring")
    }

    // MARK: - Polling

    private func poll() {
        let score = computeScore()
        let context = buildContext()

        switch state {

        case .idle:
            if score >= 35 {
                state = .possibleMeeting
                possibleMeetingStart = Date()
                lastKnownContext = context
                logger.info("TeamsMeetingDetector: IDLE → POSSIBLE_MEETING (score=\(score))")
                if let ctx = context {
                    onEvent?(.potentialMeetingDetected(ctx))
                }
            }

        case .possibleMeeting:
            if score >= 35 {
                let elapsed = Date().timeIntervalSince(possibleMeetingStart ?? Date())
                if elapsed >= 8.0 {
                    state = .inMeeting
                    let ctx = context ?? lastKnownContext ?? makeUnknownContext()
                    lastKnownContext = ctx
                    logger.info("TeamsMeetingDetector: POSSIBLE_MEETING → IN_MEETING")
                    onEvent?(.meetingStarted(ctx))
                }
            } else {
                // Signals dropped before confirmed — back to idle
                state = .idle
                possibleMeetingStart = nil
                logger.info("TeamsMeetingDetector: POSSIBLE_MEETING → IDLE (score dropped, score=\(score))")
            }

        case .inMeeting:
            if score < 20 {
                state = .possibleEnd
                possibleEndStart = Date()
                logger.info("TeamsMeetingDetector: IN_MEETING → POSSIBLE_END (score=\(score))")
            } else if let ctx = context {
                lastKnownContext = ctx
            }

        case .possibleEnd:
            if score >= 20 {
                // Signals returned — meeting still ongoing
                state = .inMeeting
                possibleEndStart = nil
                logger.info("TeamsMeetingDetector: POSSIBLE_END → IN_MEETING (score recovered, score=\(score))")
            } else {
                let elapsed = Date().timeIntervalSince(possibleEndStart ?? Date())
                if elapsed >= 12.0 {
                    let ctx = lastKnownContext ?? makeUnknownContext()
                    state = .idle
                    possibleEndStart = nil
                    lastKnownContext = nil
                    logger.info("TeamsMeetingDetector: POSSIBLE_END → IDLE (meeting ended)")
                    onEvent?(.meetingEnded(ctx))
                }
            }
        }
    }

    // MARK: - Score computation

    private func computeScore() -> Int {
        var score = 0

        let running = NSWorkspace.shared.runningApplications
        guard let teamsApp = running.first(where: { app in
            guard let bundle = app.bundleIdentifier else { return false }
            return Self.teamsBundleIDs.contains(bundle)
        }) else {
            return 0   // Teams not running at all
        }

        // Teams process is running: +15
        score += 15

        // Teams is the active (frontmost) application: +15
        if teamsApp.isActive {
            score += 15
        }

        // Microphone is in use by any process: +30
        // This is the strongest call signal — mic activates when a call starts.
        if isMicrophoneInUse() {
            score += 30
        }

        // Teams has been running for >30s — not just launching: +10
        if let launchDate = teamsApp.launchDate,
           Date().timeIntervalSince(launchDate) > 30 {
            score += 10
        }

        logger.debug("TeamsMeetingDetector: score=\(score) (active=\(teamsApp.isActive) mic=\(self.isMicrophoneInUse()))")
        return score
    }

    /// Returns true if any audio input device is currently being used.
    /// AVCaptureDevice.isInUseByAnotherApplication reflects real mic activity.
    private func isMicrophoneInUse() -> Bool {
        AVCaptureDevice.devices(for: .audio).contains { $0.isInUseByAnotherApplication }
    }

    // MARK: - Context helpers

    private func buildContext() -> MeetingContext? {
        let running = NSWorkspace.shared.runningApplications
        guard let teamsApp = running.first(where: { app in
            guard let bundle = app.bundleIdentifier else { return false }
            return Self.teamsBundleIDs.contains(bundle)
        }) else {
            return nil
        }

        return MeetingContext(
            applicationName: teamsApp.localizedName ?? "Microsoft Teams",
            bundleIdentifier: teamsApp.bundleIdentifier ?? "com.microsoft.teams2",
            detectedTitle: nil,
            detectedAt: Date()
        )
    }

    private func makeUnknownContext() -> MeetingContext {
        MeetingContext(
            applicationName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            detectedTitle: nil,
            detectedAt: Date()
        )
    }
}
