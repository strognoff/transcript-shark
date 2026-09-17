//
//  RecordingCaptureScope.swift
//  MeetingRecorder
//
//  User-selectable capture area configuration for ScreenCaptureKit recording.
//

import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated let kRecordingCaptureModeKey = "recordingCaptureMode"
nonisolated let kSelectedCaptureWindowIDKey = "selectedCaptureWindowID"
nonisolated let kSelectedCaptureWindowLabelKey = "selectedCaptureWindowLabel"

enum RecordingCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case wholeScreen
    case selectedWindow

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .wholeScreen:
            return "Whole Screen"
        case .selectedWindow:
            return "Selected Window"
        }
    }

    nonisolated static func resolved(from rawValue: String?) -> RecordingCaptureMode {
        rawValue.flatMap(RecordingCaptureMode.init(rawValue:)) ?? .wholeScreen
    }
}

struct SelectableCaptureWindow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let applicationName: String
    let bundleIdentifier: String?
    let frame: CGRect

    var displayName: String {
        if title.isEmpty {
            return applicationName
        }
        return "\(applicationName) — \(title)"
    }
}

enum RecordingCaptureScope: Equatable, Sendable {
    case wholeScreen
    case selectedWindow(windowID: String, fallbackToWholeScreen: Bool = true)
}

@MainActor
protocol CaptureWindowProviding: AnyObject {
    func availableWindows() async -> [SelectableCaptureWindow]
    func constraintRect(for windowID: String) async -> CGRect?
}

@MainActor
final class ScreenCaptureWindowProvider: CaptureWindowProviding {

    func availableWindows() async -> [SelectableCaptureWindow] {
        do {
            let content = try await Self.shareableContent(onScreenWindowsOnly: true)
            return Self.selectableWindows(from: content)
        } catch {
            return []
        }
    }

    func constraintRect(for windowID: String) async -> CGRect? {
        do {
            let content = try await Self.shareableContent(onScreenWindowsOnly: true)
            return Self.window(matching: windowID, in: content)?.frame
        } catch {
            return nil
        }
    }

    static func shareableContent(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly)
    }

    static func selectableWindows(from content: SCShareableContent) -> [SelectableCaptureWindow] {
        content.windows
            .compactMap(Self.selectableWindow(from:))
            .sorted { lhs, rhs in
                let appComparison = lhs.applicationName.localizedCaseInsensitiveCompare(rhs.applicationName)
                if appComparison == .orderedSame {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return appComparison == .orderedAscending
            }
    }

    static func window(matching windowID: String, in content: SCShareableContent) -> SCWindow? {
        guard let numericID = UInt32(windowID) else { return nil }
        return content.windows.first { $0.windowID == numericID }
    }

    private static func selectableWindow(from window: SCWindow) -> SelectableCaptureWindow? {
        let frame = window.frame
        guard frame.width >= 80, frame.height >= 80 else { return nil }

        let application = window.owningApplication
        let applicationName = application?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown App"
        let bundleIdentifier = application?.bundleIdentifier

        if bundleIdentifier == Bundle.main.bundleIdentifier || applicationName == "Transcript Shark" || applicationName == "MeetingRecorder" {
            return nil
        }

        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectableCaptureWindow(
            id: String(window.windowID),
            title: title,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            frame: frame
        )
    }
}
