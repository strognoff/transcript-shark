//
//  MeetingDetectionService.swift
//  MeetingRecorder
//
//  Protocol and event types for meeting detection.
//  Detectors emit events — they never touch recording APIs directly.
//

import Foundation

// MARK: - Detector Protocol

protocol MeetingDetector: AnyObject {
    func startMonitoring()
    func stopMonitoring()
}

// MARK: - Events

enum MeetingDetectionEvent {
    case meetingStarted(MeetingContext)
    case meetingEnded(MeetingContext)
    case potentialMeetingDetected(MeetingContext)
}

// MARK: - Context

struct MeetingContext: Sendable {
    let applicationName: String
    let bundleIdentifier: String
    let detectedTitle: String?
    let detectedAt: Date
}
