//
//  AudioCaptureService.swift
//  MeetingRecorder
//
//  Protocol that decouples RecordingCoordinator from the concrete
//  SCStream/SCRecordingOutput implementation. UI code and the coordinator
//  reference only this protocol — never AudioCapture directly.
//

import Foundation

/// The coordinator interacts with audio capture exclusively through this protocol.
@MainActor
protocol AudioCaptureService: AnyObject {

    /// The URL where the captured audio/video will be written.
    var outputURL: URL { get }

    /// Start capturing. Throws if permissions are denied or setup fails.
    func start() async throws

    /// Stop capturing and finalise the output file.
    func stop() async throws
}
