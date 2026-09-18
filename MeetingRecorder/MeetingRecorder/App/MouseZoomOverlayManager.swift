//
//  MouseZoomOverlayManager.swift
//  MeetingRecorder
//
//  Shows a recording-only magnifier around the cursor while a configured
//  modifier key is held.
//

import AppKit
import ScreenCaptureKit

nonisolated let kMouseZoomEnabledKey = "mouseZoomEnabled"
nonisolated let kMouseZoomActivationModifierKey = "mouseZoomActivationModifier"

enum MouseZoomActivationModifier: String, CaseIterable, Identifiable {
    case command
    case option
    case control

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        }
    }

    var eventModifier: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        }
    }

    static func resolved(from rawValue: String?) -> MouseZoomActivationModifier {
        guard let rawValue, let modifier = MouseZoomActivationModifier(rawValue: rawValue) else {
            return .command
        }
        return modifier
    }
}

@MainActor
protocol MouseZoomOverlayManaging: AnyObject {
    var isRecording: Bool { get }
    func setEnabled(_ enabled: Bool)
    func setActivationModifier(_ modifier: MouseZoomActivationModifier)
    func recordingDidStart()
    func recordingDidStop()
}

@MainActor
final class MouseZoomOverlayManager: MouseZoomOverlayManaging {

    private let lensSize = CGSize(width: 240, height: 160)
    private let sourceSize = CGSize(width: 120, height: 80)
    private let screenInset: CGFloat = 16
    private let pollInterval: TimeInterval = 1.0 / 30.0
    private let captureInterval: TimeInterval = 1.0 / 8.0

    private var enabled: Bool
    private var activationModifier: MouseZoomActivationModifier
    private(set) var isRecording = false
    private var isModifierPressed = false
    private var window: NSWindow?
    private var refreshTimer: Timer?
    private var lastCaptureDate = Date.distantPast
    private var isCapturing = false
    private var lastImage: NSImage?

    init(enabled: Bool = false, activationModifier: MouseZoomActivationModifier = .command) {
        self.enabled = enabled
        self.activationModifier = activationModifier
    }

    deinit {}

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            isModifierPressed = false
            isCapturing = false
            lastImage = nil
            hideLens()
        }
        updateMonitoring()
    }

    func setActivationModifier(_ modifier: MouseZoomActivationModifier) {
        activationModifier = modifier
        isModifierPressed = currentModifierFlagsContainActivationModifier()
        if !isModifierPressed {
            hideLens()
        }
    }

    func recordingDidStart() {
        isRecording = true
        updateMonitoring()
    }

    func recordingDidStop() {
        isRecording = false
        isModifierPressed = false
        isCapturing = false
        lastImage = nil
        hideLens()
        updateMonitoring()
    }

    private func updateMonitoring() {
        if enabled && isRecording {
            startRefreshTimerIfNeeded()
        } else {
            stopRefreshTimer()
        }
    }

    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollMouseZoomState()
            }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func pollMouseZoomState() {
        guard enabled, isRecording else {
            hideLens()
            return
        }

        let modifierIsPressed = currentModifierFlagsContainActivationModifier()
        guard modifierIsPressed else {
            isModifierPressed = false
            hideLens()
            return
        }

        isModifierPressed = true
        let mouseLocation = NSEvent.mouseLocation
        showLens(at: mouseLocation)
        captureImageIfNeeded(around: mouseLocation)
    }

    private func currentModifierFlagsContainActivationModifier() -> Bool {
        NSEvent.modifierFlags.contains(activationModifier.eventModifier)
    }

    private func showLens(at screenPoint: CGPoint) {
        let window = lensWindow()
        position(window, near: screenPoint)
        if let lastImage {
            (window.contentView as? MouseZoomLensView)?.updateImage(lastImage)
        }
        window.orderFrontRegardless()
    }

    private func captureImageIfNeeded(around screenPoint: CGPoint) {
        guard !isCapturing else { return }
        guard Date().timeIntervalSince(lastCaptureDate) >= captureInterval else { return }

        isCapturing = true
        lastCaptureDate = Date()

        Task { @MainActor in
            let image = await captureImage(around: screenPoint)
            isCapturing = false
            guard enabled, isRecording, isModifierPressed else { return }
            lastImage = image
            if let image {
                (window?.contentView as? MouseZoomLensView)?.updateImage(image)
            }
        }
    }

    private func hideLens() {
        window?.orderOut(nil)
    }

    private func lensWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: lensSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = MouseZoomLensView(frame: NSRect(origin: .zero, size: lensSize))
        self.window = window
        return window
    }

    private func position(_ window: NSWindow, near screenPoint: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        var origin = CGPoint(
            x: screenPoint.x + 24,
            y: screenPoint.y + 24
        )

        if origin.x + lensSize.width > frame.maxX - screenInset {
            origin.x = screenPoint.x - lensSize.width - 24
        }
        if origin.y + lensSize.height > frame.maxY - screenInset {
            origin.y = screenPoint.y - lensSize.height - 24
        }

        origin.x = min(max(origin.x, frame.minX + screenInset), frame.maxX - lensSize.width - screenInset)
        origin.y = min(max(origin.y, frame.minY + screenInset), frame.maxY - lensSize.height - screenInset)

        window.setFrame(NSRect(origin: origin, size: lensSize), display: true)
    }

    private func captureImage(around screenPoint: CGPoint) async -> NSImage? {
        do {
            let content = try await ScreenCaptureWindowProvider.shareableContent(onScreenWindowsOnly: false)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main,
                  let display = display(matching: screen, in: content) ?? content.displays.first else { return nil }
            let sourceRect = captureRect(around: screenPoint, in: screen, display: display)
            let configuration = SCStreamConfiguration()
            configuration.width = max(2, Int(sourceRect.width.rounded(.up)))
            configuration.height = max(2, Int(sourceRect.height.rounded(.up)))
            configuration.sourceRect = sourceRect
            configuration.showsCursor = true

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: cgImage, size: sourceSize)
        } catch {
            return nil
        }
    }

    private func display(matching screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            if let exactMatch = content.displays.first(where: { $0.displayID == displayID }) {
                return exactMatch
            }
        }

        return content.displays.max { lhs, rhs in
            intersectionArea(lhs.frame, screen.frame) < intersectionArea(rhs.frame, screen.frame)
        }
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func captureRect(around screenPoint: CGPoint, in screen: NSScreen, display: SCDisplay) -> CGRect {
        let scaleX = CGFloat(display.width) / max(screen.frame.width, 1)
        let scaleY = CGFloat(display.height) / max(screen.frame.height, 1)
        let localPoint = CGPoint(
            x: (screenPoint.x - screen.frame.minX) * scaleX,
            y: (screen.frame.maxY - screenPoint.y) * scaleY
        )
        let sourcePixelSize = CGSize(
            width: sourceSize.width * scaleX,
            height: sourceSize.height * scaleY
        )
        let proposed = CGRect(
            x: localPoint.x - sourcePixelSize.width / 2,
            y: localPoint.y - sourcePixelSize.height / 2,
            width: sourcePixelSize.width,
            height: sourcePixelSize.height
        )
        return proposed.intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))
    }
}

private final class MouseZoomLensView: NSView {

    private let imageView = NSImageView()
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = 22
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        addSubview(imageView)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.systemYellow.withAlphaComponent(0.95).cgColor
        borderLayer.lineWidth = 4
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updateImage(_ image: NSImage?) {
        imageView.image = image
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        layer?.cornerRadius = 22
        borderLayer.frame = bounds
        borderLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: 20, cornerHeight: 20, transform: nil)
    }
}
