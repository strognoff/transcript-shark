//
//  TeamsMeetingDetector.swift
//  MeetingRecorder
//
//  Polls NSWorkspace and CGWindowList every 2 seconds to detect whether a
//  Microsoft Teams meeting is in progress. Emits MeetingDetectionEvents —
//  never calls any recording API directly.
//
//  State machine:
//    IDLE → POSSIBLE_MEETING (score ≥ 50) → IN_MEETING (stable 3 s)
//    IN_MEETING → POSSIBLE_END (score < 30) → IDLE (stable 8 s)
//    POSSIBLE_END → IN_MEETING (signals return before 8 s)
//

import AppKit
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

    private static let meetingKeywords: [String] = [
        "Meeting", "Call", "Video", "Audio", "Conference", "Live", "Recording"
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
            if score >= 50 {
                state = .possibleMeeting
                possibleMeetingStart = Date()
                lastKnownContext = context
                logger.debug("TeamsMeetingDetector: IDLE → POSSIBLE_MEETING (score=\(score))")
                if let ctx = context {
                    onEvent?(.potentialMeetingDetected(ctx))
                }
            }

        case .possibleMeeting:
            if score >= 50 {
                let elapsed = Date().timeIntervalSince(possibleMeetingStart ?? Date())
                if elapsed >= 3.0 {
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
                logger.debug("TeamsMeetingDetector: POSSIBLE_MEETING → IDLE (score dropped, score=\(score))")
            }

        case .inMeeting:
            if score < 30 {
                state = .possibleEnd
                possibleEndStart = Date()
                logger.debug("TeamsMeetingDetector: IN_MEETING → POSSIBLE_END (score=\(score))")
            } else if let ctx = context {
                lastKnownContext = ctx
            }

        case .possibleEnd:
            if score >= 30 {
                // Signals returned — meeting still ongoing
                state = .inMeeting
                possibleEndStart = nil
                logger.debug("TeamsMeetingDetector: POSSIBLE_END → IN_MEETING (score recovered, score=\(score))")
            } else {
                let elapsed = Date().timeIntervalSince(possibleEndStart ?? Date())
                if elapsed >= 8.0 {
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

        // Teams process running: +10
        score += 10

        // Teams is active (has keyboard focus): +10
        if teamsApp.isActive {
            score += 10
        }

        // Teams is frontmost: +5
        if teamsApp.isActive {
            score += 5
        }

        // Window title contains meeting keyword: +30
        if hasMeetingWindow(pid: teamsApp.processIdentifier) {
            score += 30
        }

        return score
    }

    // MARK: - Window title detection (CGWindowList — no Accessibility permission needed)

    private func hasMeetingWindow(pid: pid_t) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowName = windowInfo[kCGWindowName as String] as? String else {
                continue
            }
            for keyword in Self.meetingKeywords {
                if windowName.localizedCaseInsensitiveContains(keyword) {
                    return true
                }
            }
        }
        return false
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

        let title = meetingWindowTitle(pid: teamsApp.processIdentifier)
        return MeetingContext(
            applicationName: teamsApp.localizedName ?? "Microsoft Teams",
            bundleIdentifier: teamsApp.bundleIdentifier ?? "com.microsoft.teams2",
            detectedTitle: title,
            detectedAt: Date()
        )
    }

    private func meetingWindowTitle(pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowName = windowInfo[kCGWindowName as String] as? String else {
                continue
            }
            for keyword in Self.meetingKeywords {
                if windowName.localizedCaseInsensitiveContains(keyword) {
                    return windowName
                }
            }
        }
        return nil
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
