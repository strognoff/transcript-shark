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

@MainActor
protocol CameraOverlayManaging: AnyObject {
    var isVisible: Bool { get }
    var availableCameras: [CameraDevice] { get }
    func setSelectedCameraID(_ cameraID: String?)
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
        let previewView = CameraPreviewView(frame: NSRect(origin: .zero, size: bubbleSize))
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = frameRect.width / 2
        layer?.masksToBounds = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        previewLayer?.frame = bounds
    }
}
