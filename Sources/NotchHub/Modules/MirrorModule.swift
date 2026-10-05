import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Owns the AVCaptureSession AND its preview layer. Every session mutation (configure, attach
/// the preview layer, mirror, start, stop) runs on one private serial queue, in that order.
/// Attaching a preview layer adds a connection to the session; doing that on the main thread
/// while `startRunning` enumerates connections on the queue threw
/// "collection was mutated while being enumerated" and aborted the app (2026-10-05 crash).
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let queue = DispatchQueue(label: "com.pritesh.notchhub.camera")
    private var configured = false

    /// Calls back on the main actor with false when there is no usable camera.
    func start(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let ok = self.configureIfNeeded()
            if ok, !self.session.isRunning { self.session.startRunning() }
            Task { @MainActor in done(ok) }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Runs on `queue`, never concurrently with start/stop.
    private func configureIfNeeded() -> Bool {
        if configured { return true }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        guard !session.inputs.isEmpty else { return false }

        // Attach the preview layer here, before the session ever runs, so the connection it adds
        // can never race `startRunning`. Mirroring goes through the connection when supported.
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        var mirroredByConnection = false
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
            mirroredByConnection = true
        }
        let flip = !mirroredByConnection
        let layer = previewLayer
        DispatchQueue.main.async {
            layer.setAffineTransform(flip ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        }
        configured = true
        return true
    }
}

/// Module 9: a camera mirror. The session runs ONLY while the Mirror tab is visible.
@MainActor
final class MirrorModule: ObservableObject, NotchModule {
    enum Access: Equatable { case notDetermined, granted, denied, noCamera }

    let id = "mirror"
    let title = "Mirror"
    let systemImage = "person.crop.square"
    let panelHeight: CGFloat = 220

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var isRunning = false

    let camera = CameraSession()
    private var visible = false
    private var requesting = false

    func start() { access = Self.currentAccess() }

    func stop() {
        visible = false
        stopSession()
    }

    private static func currentAccess() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func visibilityChanged(expanded: Bool, selected: Bool) {
        visible = selected
        if selected {
            if access != .noCamera { access = Self.currentAccess() }
            switch access {
            case .granted: startSession()
            case .notDetermined: requestAccess()  // first use of the tab
            case .denied, .noCamera: break
            }
        } else {
            stopSession()
        }
    }

    func requestAccess() {
        guard !requesting else { return }
        requesting = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.requesting = false
                self.access = granted ? .granted : .denied
                if granted, self.visible { self.startSession() }
            }
        }
    }

    private func startSession() {
        guard !isRunning else { return }
        isRunning = true
        camera.start { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.access = .noCamera
                self.isRunning = false
            } else if !self.visible {
                self.stopSession()  // tab closed while the camera was starting
            }
        }
    }

    private func stopSession() {
        guard isRunning else { return }
        isRunning = false
        camera.stop()
    }

    var expandedView: AnyView { AnyView(MirrorView(module: self)) }
    var settingsView: AnyView {
        AnyView(Text("Camera access is requested the first time you open the Mirror tab. The camera runs only while that tab is visible; nothing is recorded.")
            .font(.caption).foregroundColor(.secondary))
    }
}

struct MirrorView: View {
    @ObservedObject var module: MirrorModule

    var body: some View {
        switch module.access {
        case .granted:
            CameraPreview(layer: module.camera.previewLayer, running: module.isRunning)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 14)
        case .notDetermined:
            PermissionNotice(systemImage: "camera", message: "Mirror shows your camera while this tab is open.",
                             buttonTitle: "Allow camera") { module.requestAccess() }
        case .denied:
            PermissionNotice(systemImage: "video.slash",
                             message: "Camera access is off. Turn on NotchHub under Privacy & Security › Camera.",
                             settingsURL: SystemSettingsURL.camera)
        case .noCamera:
            PermissionNotice(systemImage: "video.slash", message: "No camera available (lid closed or in use?).",
                             buttonTitle: "Try again") { module.visibilityChanged(expanded: true, selected: true) }
        }
    }
}

/// Hosts the session's own preview layer in an NSView. The view only positions the layer; it
/// never touches the session or its connections (see CameraSession).
struct CameraPreview: NSViewRepresentable {
    var layer: AVCaptureVideoPreviewLayer
    var running: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(layer)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.needsLayout = true
    }

    final class PreviewView: NSView {
        private var preview: AVCaptureVideoPreviewLayer?

        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            wantsLayer = true
            self.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            preview = layer
            self.layer?.addSublayer(layer)
        }

        override func layout() {
            super.layout()
            guard let preview else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.bounds = bounds
            preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}
