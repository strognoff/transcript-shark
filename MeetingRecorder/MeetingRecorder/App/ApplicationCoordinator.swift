//
//  ApplicationCoordinator.swift
//  MeetingRecorder
//
//  Bridges meeting detection events to AppState recording actions.
//  Owns the TeamsMeetingDetector and reacts to its events without
//  coupling the detector to any recording or UI logic.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "ApplicationCoordinator")

// MARK: - Notification names

extension Notification.Name {
    /// Posted when a potential (unconfirmed) meeting is detected.
    static let potentialMeetingDetected = Notification.Name("com.transcript-shark.potentialMeetingDetected")
}

// MARK: - Coordinator

@MainActor
final class ApplicationCoordinator {

    // MARK: - Dependencies

    private weak var appState: AppState?
    private let detector: TeamsMeetingDetector

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
        self.detector = TeamsMeetingDetector()
        self.detector.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        detector.startMonitoring()
        logger.info("ApplicationCoordinator: monitoring started")
    }

    func stopMonitoring() {
        detector.stopMonitoring()
        logger.info("ApplicationCoordinator: monitoring stopped")
    }

    // MARK: - Event handling

    private func handle(event: MeetingDetectionEvent) {
        switch event {

        case .meetingStarted(let context):
            logger.info("ApplicationCoordinator: meetingStarted — \(context.applicationName)")
            guard let state = appState else { return }
            guard !state.isRecording else {
                logger.info("ApplicationCoordinator: recording already in progress — ignoring meetingStarted")
                return
            }
            Task { @MainActor in
                await state.startRecording(application: context.applicationName)
            }

        case .meetingEnded(let context):
            logger.info("ApplicationCoordinator: meetingEnded — \(context.applicationName)")
            guard let state = appState else { return }
            guard state.isRecording else {
                logger.info("ApplicationCoordinator: not recording — ignoring meetingEnded")
                return
            }
            Task { @MainActor in
                await state.stopRecording()
            }

        case .potentialMeetingDetected(let context):
            logger.debug("ApplicationCoordinator: potentialMeetingDetected — \(context.applicationName)")
            NotificationCenter.default.post(
                name: .potentialMeetingDetected,
                object: nil,
                userInfo: ["context": context]
            )
        }
    }
}
