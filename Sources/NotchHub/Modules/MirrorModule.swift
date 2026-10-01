import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Owns the AVCaptureSession; every start/stop runs on a private serial queue (startRunning
/// blocks). Touched from the main thread only to hand the session to the preview layer.
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
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

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        configured = !session.inputs.isEmpty
        return configured
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
            CameraPreview(session: module.camera.session, running: module.isRunning)
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

/// AVCaptureVideoPreviewLayer in an NSView, mirrored horizontally.
struct CameraPreview: NSViewRepresentable {
    var session: AVCaptureSession
    var running: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.needsLayout = true
    }

    final class PreviewView: NSView {
        private let preview = AVCaptureVideoPreviewLayer()

        func attach(_ session: AVCaptureSession) {
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            preview.session = session
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.bounds = bounds
            preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // Mirror: through the connection when supported, else by flipping the layer.
            if let connection = preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
                preview.setAffineTransform(.identity)
            } else {
                preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            }
            CATransaction.commit()
        }
    }
}
