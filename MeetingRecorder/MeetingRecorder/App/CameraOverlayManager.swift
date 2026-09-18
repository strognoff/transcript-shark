//
//  CameraOverlayManager.swift
//  MeetingRecorder
//
//  Presents a manually controlled, always-on-top circular camera preview.
//

import AppKit
import AVFoundation
import OSLog

struct CameraDevice: Identifiable, Equatable {
    let id: String
    let localizedName: String
}

nonisolated let kCameraBubbleStyleKey = "cameraBubbleStyle"

enum CameraBubbleStyle: String, CaseIterable, Identifiable {
    case classic
    case neon
    case fire
    case cracked
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .neon: return "Neon"
        case .fire: return "Fire"
        case .cracked: return "Cracked Glass"
        case .minimal: return "Minimal"
        }
    }

    static func resolved(from rawValue: String?) -> CameraBubbleStyle {
        guard let rawValue, let style = CameraBubbleStyle(rawValue: rawValue) else {
            return .classic
        }
        return style
    }
}

@MainActor
protocol CameraOverlayManaging: AnyObject {
    var isVisible: Bool { get }
    var availableCameras: [CameraDevice] { get }
    func setSelectedCameraID(_ cameraID: String?)
    func setBubbleStyle(_ style: CameraBubbleStyle)
    func setMovementConstraint(_ rect: CGRect?)
    func setVisible(_ visible: Bool) async -> Bool
    func hide()
}

@MainActor
final class CameraOverlayManager: NSObject, CameraOverlayManaging {

    private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "CameraOverlayManager")
    private let bubbleSize = CGSize(width: 176, height: 176)
    private let screenInset: CGFloat = 24

    private var window: NSWindow?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var selectedCameraID: String?
    private var bubbleStyle: CameraBubbleStyle = .classic
    private var movementConstraint: CGRect?

    var isVisible: Bool {
        window?.isVisible == true
    }

    var availableCameras: [CameraDevice] {
        discoverCameras().map {
            CameraDevice(id: $0.uniqueID, localizedName: $0.localizedName)
        }
    }

    func setSelectedCameraID(_ cameraID: String?) {
        selectedCameraID = cameraID
    }

    func setBubbleStyle(_ style: CameraBubbleStyle) {
        bubbleStyle = style
        (window?.contentView as? CameraPreviewView)?.apply(style: style)
    }

    func setMovementConstraint(_ rect: CGRect?) {
        guard let rect, rect.width >= bubbleSize.width, rect.height >= bubbleSize.height else {
            movementConstraint = nil
            return
        }

        movementConstraint = rect
        clampWindowToConstraint()
    }

    @discardableResult
    func setVisible(_ visible: Bool) async -> Bool {
        if visible {
            return await show()
        }

        hide()
        return false
    }

    func hide() {
        captureSession?.stopRunning()
        captureSession = nil
        previewLayer = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
    }

    private func show() async -> Bool {
        guard await requestCameraAccessIfNeeded() else {
            logger.warning("CameraOverlayManager: camera permission denied")
            return false
        }

        hide()

        guard let session = makeCaptureSession() else {
            logger.error("CameraOverlayManager: unable to create capture session")
            return false
        }

        let overlayWindow = makeOverlayWindow()
        let previewView = CameraPreviewView(frame: NSRect(origin: .zero, size: bubbleSize), style: bubbleStyle)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds
        previewView.previewLayer = layer
        previewView.layer?.addSublayer(layer)
        overlayWindow.contentView = previewView

        window = overlayWindow
        captureSession = session
        previewLayer = layer

        session.startRunning()
        overlayWindow.orderFrontRegardless()
        positionWindow(overlayWindow)
        return true
    }

    private func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func makeCaptureSession() -> AVCaptureSession? {
        guard let camera = selectedCamera() else {
            return nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            let session = AVCaptureSession()
            session.sessionPreset = .medium
            guard session.canAddInput(input) else { return nil }
            session.addInput(input)
            return session
        } catch {
            logger.error("CameraOverlayManager: failed to configure camera input — \(error.localizedDescription)")
            return nil
        }
    }

    private func selectedCamera() -> AVCaptureDevice? {
        let cameras = discoverCameras()

        if let selectedCameraID,
           let selectedCamera = cameras.first(where: { $0.uniqueID == selectedCameraID }) {
            return selectedCamera
        }

        return cameras.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
    }

    private func discoverCameras() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    private func makeOverlayWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: bubbleSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        return window
    }

    private func positionWindow(_ window: NSWindow) {
        let bounds = movementConstraint ?? NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        guard let bounds else { return }

        let origin = NSPoint(
            x: bounds.maxX - bubbleSize.width - screenInset,
            y: bounds.minY + screenInset
        )
        window.setFrame(clampedFrame(NSRect(origin: origin, size: bubbleSize), in: bounds), display: true)
    }

    private func clampWindowToConstraint() {
        guard let window, let movementConstraint else { return }
        let clamped = clampedFrame(window.frame, in: movementConstraint)
        guard clamped != window.frame else { return }
        window.setFrame(clamped, display: true)
    }

    private func clampedFrame(_ frame: NSRect, in bounds: CGRect) -> NSRect {
        let insetBounds = bounds.insetBy(dx: screenInset, dy: screenInset)
        let usableBounds = insetBounds.width >= bubbleSize.width && insetBounds.height >= bubbleSize.height ? insetBounds : bounds

        let minX = usableBounds.minX
        let maxX = usableBounds.maxX - frame.width
        let minY = usableBounds.minY
        let maxY = usableBounds.maxY - frame.height

        let clampedX = min(max(frame.origin.x, minX), maxX)
        let clampedY = min(max(frame.origin.y, minY), maxY)

        return NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: frame.size)
    }
}

extension CameraOverlayManager: NSWindowDelegate {
    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.clampWindowToConstraint()
        }
    }
}

private final class CameraPreviewView: NSView {

    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let cameraMaskLayer = CALayer()
    private let styleLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private let accentLayer = CAShapeLayer()
    private let crackedLayer = CAShapeLayer()
    private var style: CameraBubbleStyle

    init(frame frameRect: NSRect, style: CameraBubbleStyle) {
        self.style = style
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        cameraMaskLayer.backgroundColor = NSColor.black.cgColor
        cameraMaskLayer.masksToBounds = true
        layer?.addSublayer(cameraMaskLayer)

        styleLayer.masksToBounds = false
        layer?.addSublayer(styleLayer)
        styleLayer.addSublayer(ringLayer)
        styleLayer.addSublayer(accentLayer)
        styleLayer.addSublayer(crackedLayer)

        apply(style: style)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(style: CameraBubbleStyle) {
        self.style = style
        resetStyleLayers()

        cameraMaskLayer.borderWidth = 0
        cameraMaskLayer.borderColor = nil
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 0
        layer?.shadowColor = nil
        layer?.shadowOffset = .zero

        switch style {
        case .classic:
            cameraMaskLayer.borderWidth = 2
            cameraMaskLayer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
            layer?.shadowOpacity = 0.25
            layer?.shadowRadius = 10
            layer?.shadowColor = NSColor.black.cgColor

        case .neon:
            cameraMaskLayer.borderWidth = 2
            cameraMaskLayer.borderColor = NSColor.systemCyan.cgColor
            layer?.shadowOpacity = 0.85
            layer?.shadowRadius = 18
            layer?.shadowColor = NSColor.systemCyan.cgColor
            ringLayer.isHidden = false
            ringLayer.strokeColor = NSColor.systemCyan.cgColor
            ringLayer.lineWidth = 4
            addPulseAnimation(to: ringLayer, from: 0.45, to: 1.0, duration: 1.4)

        case .fire:
            cameraMaskLayer.borderWidth = 2
            cameraMaskLayer.borderColor = NSColor.systemOrange.cgColor
            layer?.shadowOpacity = 0.9
            layer?.shadowRadius = 20
            layer?.shadowColor = NSColor.systemOrange.cgColor
            ringLayer.isHidden = false
            ringLayer.strokeColor = NSColor.systemOrange.cgColor
            ringLayer.lineWidth = 5
            accentLayer.isHidden = false
            accentLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
            accentLayer.lineWidth = 2
            addPulseAnimation(to: ringLayer, from: 0.55, to: 1.0, duration: 0.8)
            addRotationAnimation(to: accentLayer, duration: 4.0)

        case .cracked:
            cameraMaskLayer.borderWidth = 3
            cameraMaskLayer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = 8
            layer?.shadowColor = NSColor.black.cgColor
            crackedLayer.isHidden = false
            crackedLayer.strokeColor = NSColor.white.withAlphaComponent(0.78).cgColor
            crackedLayer.lineWidth = 1.8
            crackedLayer.lineCap = .round
            crackedLayer.lineJoin = .round

        case .minimal:
            break
        }

        needsLayout = true
    }

    private func resetStyleLayers() {
        for layer in [ringLayer, accentLayer, crackedLayer] {
            layer.removeAllAnimations()
            layer.fillColor = NSColor.clear.cgColor
            layer.strokeColor = NSColor.clear.cgColor
            layer.lineWidth = 0
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            layer.path = nil
            layer.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let radius = min(bounds.width, bounds.height) / 2
        cameraMaskLayer.frame = bounds
        cameraMaskLayer.cornerRadius = radius
        previewLayer?.frame = bounds

        if let previewLayer, previewLayer.superlayer !== cameraMaskLayer {
            previewLayer.removeFromSuperlayer()
            cameraMaskLayer.addSublayer(previewLayer)
        }

        styleLayer.frame = bounds
        ringLayer.frame = bounds
        accentLayer.frame = bounds
        crackedLayer.frame = bounds

        let ringRect = bounds.insetBy(dx: 4, dy: 4)
        ringLayer.path = ringLayer.isHidden ? nil : CGPath(ellipseIn: ringRect, transform: nil)
        accentLayer.path = accentLayer.isHidden ? nil : accentPath(in: bounds)
        crackedLayer.path = crackedLayer.isHidden ? nil : crackedPath(in: bounds)
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)

        CATransaction.commit()
    }

    private func accentPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 8
        path.addArc(center: center, radius: radius, startAngle: -.pi / 4, endAngle: .pi / 3, clockwise: false)
        path.addArc(center: center, radius: radius - 6, startAngle: .pi * 0.75, endAngle: .pi * 1.35, clockwise: false)
        return path
    }

    private func crackedPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let points: [(CGPoint, [CGPoint])] = [
            (CGPoint(x: center.x - 10, y: center.y + 20), [
                CGPoint(x: center.x - 44, y: center.y + 54),
                CGPoint(x: center.x - 22, y: center.y + 6),
                CGPoint(x: center.x - 58, y: center.y - 18)
            ]),
            (CGPoint(x: center.x + 18, y: center.y + 10), [
                CGPoint(x: center.x + 58, y: center.y + 38),
                CGPoint(x: center.x + 34, y: center.y - 4),
                CGPoint(x: center.x + 62, y: center.y - 42)
            ]),
            (CGPoint(x: center.x - 4, y: center.y - 12), [
                CGPoint(x: center.x - 26, y: center.y - 54),
                CGPoint(x: center.x + 12, y: center.y - 34)
            ])
        ]

        for (origin, branches) in points {
            for branch in branches {
                path.move(to: origin)
                path.addLine(to: branch)
            }
        }
        return path
    }

    private func addPulseAnimation(to layer: CALayer, from: Float, to: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "pulse")
    }

    private func addRotationAnimation(to layer: CALayer, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = duration
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "rotation")
    }
}
