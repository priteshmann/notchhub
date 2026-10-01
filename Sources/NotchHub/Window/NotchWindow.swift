import AppKit
import Combine
import SwiftUI

/// Notch position in screen coordinates (AppKit, origin bottom-left).
struct NotchGeometry: Equatable {
    var centerX: CGFloat
    var screenTop: CGFloat
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    static let fallbackSize = CGSize(width: 200, height: 32)

    /// The built-in (notched) screen, else the main screen.
    @MainActor
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    @MainActor
    static func current() -> NotchGeometry {
        guard let screen = targetScreen() else {
            return NotchGeometry(centerX: 0, screenTop: 0, width: fallbackSize.width,
                                 height: fallbackSize.height, hasNotch: false)
        }
        return compute(screenFrame: screen.frame,
                       safeTop: screen.safeAreaInsets.top,
                       leftArea: screen.auxiliaryTopLeftArea,
                       rightArea: screen.auxiliaryTopRightArea)
    }

    static func compute(screenFrame: NSRect, safeTop: CGFloat,
                        leftArea: NSRect?, rightArea: NSRect?) -> NotchGeometry {
        if safeTop > 0, let left = leftArea, let right = rightArea {
            let width = screenFrame.width - left.width - right.width
            if width > 0 {
                return NotchGeometry(centerX: screenFrame.minX + left.width + width / 2,
                                     screenTop: screenFrame.maxY,
                                     width: width, height: safeTop, hasNotch: true)
            }
        }
        return NotchGeometry(centerX: screenFrame.midX, screenTop: screenFrame.maxY,
                             width: fallbackSize.width, height: fallbackSize.height, hasNotch: false)
    }
}

/// Borderless, non-activating panel that floats over the menu bar on every Space.
final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit would otherwise push the frame below the menu bar; the notch IS the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Hosting view: first click goes straight to the buttons, never activates the app.
/// Also the file drop target for the Shelf and the right-click menu of the collapsed notch.
final class NotchHostingView: NSHostingView<NotchRootView> {
    /// Files dragged over the black shape (true = over it). Returns whether a drop is accepted.
    var onFileDragOver: ((Bool) -> Void)?
    var onFileDrop: (([URL]) -> Bool)?
    /// Menu for a right-click; nil = let SwiftUI handle the click.
    var contextMenuProvider: (() -> NSMenu?)?
    /// Whether a screen point lies inside the black shape.
    var shapeContains: ((NSPoint) -> Bool)?
    /// False while the Shelf module is turned off.
    var acceptsFileDrops: (() -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // MARK: File drops (Shelf)

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls ?? []
    }

    /// Only external file drags; our own drag-outs from the Shelf are ignored.
    private func dragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard info.draggingSource == nil, acceptsFileDrops?() ?? true, !fileURLs(info).isEmpty else { return [] }
        let over = shapeContains?(NSEvent.mouseLocation) ?? true
        onFileDragOver?(over)
        return over ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragOver?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource == nil && !fileURLs(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        return onFileDrop?(urls) ?? false
    }
}

/// Owns the panel. Hover is decided by GEOMETRY (mouse location vs the black shape's rect),
/// polled at 30 Hz, never by tracking areas: tracking areas on a resizing window re-fire
/// entered/exited during the animation and the panel oscillates.
@MainActor
final class NotchWindowController {
    let panel = NotchPanel()
    let hub: HubStore
    private let hostingView: NotchHostingView
    private var geometry = NotchGeometry.current()
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var shrinkTask: Task<Void, Never>?
    private var lastTarget: CGSize = .zero
    /// When the mouse last left the expanded shape (nil while inside).
    private var outsideSince: Date?
    /// False after a hotkey/menu expand until the mouse first enters the panel, so a panel opened
    /// from the keyboard does not instantly collapse because the mouse is elsewhere.
    private var hoverArmed = true
    /// A file drag is hovering the shape: keep the panel open on the Shelf.
    private var fileDragOver = false

    private static let collapseDelay: TimeInterval = 0.35
    private static let hoverSlack: CGFloat = 6
    static let shelfID = "shelf"

    var onFileDrop: (([URL]) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    init(hub: HubStore, openSettings: @escaping () -> Void) {
        self.hub = hub
        hostingView = NotchHostingView(rootView: NotchRootView(hub: hub, openSettings: openSettings))
        hostingView.sizingOptions = []
        hostingView.registerForDraggedTypes([.fileURL])
        panel.contentView = hostingView
        panel.onEscape = { [weak self] in self?.collapse() }
        hostingView.contextMenuProvider = { [weak self] in
            guard let self, !self.hub.expanded else { return nil }
            return self.contextMenuProvider?()
        }
        hostingView.shapeContains = { [weak self] point in
            guard let self else { return false }
            return self.shapeRect(expanded: self.hub.expanded).contains(point)
        }
        hostingView.acceptsFileDrops = { [weak self] in self?.hub.isEnabled(Self.shelfID) ?? false }
        hostingView.onFileDragOver = { [weak self] over in self?.fileDragHover(over) }
        hostingView.onFileDrop = { [weak self] urls in
            guard let self, let onFileDrop = self.onFileDrop else { return false }
            onFileDrop(urls)
            self.fileDragOver = false
            return true
        }
        hub.expandHandler = { [weak self] in self?.expand() }
        applyGeometry()

        // Any hub/module change may change the shape size; read it once values have settled.
        hub.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrame() }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged() }
            }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        updateFrame()
    }

    func show() {
        panel.orderFrontRegardless()
        DebugLog.write("show frame=\(panel.frame) level=\(panel.level.rawValue) geometry=\(geometry)")
    }

    /// `byHover` = the mouse is on the shape; otherwise (hotkey, menu) hover-collapse waits until
    /// the mouse has visited the panel once. Never resizes synchronously: the deferred hub sink
    /// grows the window on the next main-loop turn (a synchronous setFrame here renders the OLD
    /// state and SwiftUI then drops the real change).
    func expand(byHover: Bool = true) {
        outsideSince = nil
        if !byHover { hoverArmed = false }
        if !hub.expanded {
            hub.expanded = true
            DebugLog.write("expand mouse=\(NSEvent.mouseLocation) frame=\(panel.frame) shape=\(shapeRect(expanded: true))")
        }
        panel.orderFrontRegardless()
        if !byHover { panel.makeKey() } // so Esc works without a click; never activates the app
    }

    func collapse() {
        outsideSince = nil
        hoverArmed = true
        fileDragOver = false
        if hub.expanded {
            DebugLog.write("collapse mouse=\(NSEvent.mouseLocation) key=\(panel.isKeyWindow)")
        }
        hub.expanded = false
        if panel.isKeyWindow {
            // Hand keyboard focus back to the app the user was in (we never activated).
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// Debug driver: renders the hosting view (cacheDisplay) to a PNG. Returns the frames written.
    func snapshot(to url: URL) -> (host: NSRect, window: NSRect)? {
        let bounds = hostingView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        hostingView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return nil }
        return (hostingView.frame, panel.frame)
    }

    func toggleExpanded() {
        hub.expanded ? collapse() : expand(byHover: false)
    }

    func openShelf() {
        hub.select(Self.shelfID)
        expand(byHover: false)
    }

    private func fileDragHover(_ over: Bool) {
        fileDragOver = over
        guard over else { return }
        if hub.isEnabled(Self.shelfID) { hub.select(Self.shelfID) }
        expand()
    }

    // MARK: Hover by geometry

    /// Screen rect of the black shape (AppKit coordinates), computed from the CURRENT state.
    private func shapeRect(expanded: Bool) -> NSRect {
        let size = hub.shapeSize(expanded: expanded)
        return NSRect(x: geometry.centerX - size.width / 2,
                      y: geometry.screenTop - size.height,
                      width: size.width, height: size.height)
    }

    private func pollMouse() {
        let mouse = NSEvent.mouseLocation
        if hub.expanded {
            let inside = shapeRect(expanded: true)
                .insetBy(dx: -Self.hoverSlack, dy: -Self.hoverSlack)
                .contains(mouse)
            if inside || fileDragOver || hub.dragOutActive {
                if inside { hoverArmed = true }
                outsideSince = nil
            } else if !hoverArmed {
                outsideSince = nil
            } else if let since = outsideSince {
                if Date().timeIntervalSince(since) >= Self.collapseDelay { collapse() }
            } else {
                outsideSince = Date()
            }
        } else if shapeRect(expanded: false).contains(mouse) {
            expand()
        }
    }

    // MARK: Geometry + frame

    private func screenChanged() {
        applyGeometry()
        updateFrame()
    }

    private func applyGeometry() {
        geometry = NotchGeometry.current()
        if hub.notchWidth != geometry.width { hub.notchWidth = geometry.width }
        if hub.notchHeight != geometry.height { hub.notchHeight = geometry.height }
    }

    /// Grow the window BEFORE the shape animates out; shrink it only after the spring has
    /// settled, so content is never clipped. The window is a canvas, the shape is the UI.
    private func updateFrame() {
        let target = hub.shapeSize
        let current = panel.frame.size
        let grown = CGSize(width: max(current.width, target.width),
                           height: max(current.height, target.height))
        setPanelSize(grown)
        panel.hasShadow = hub.expanded
        // Module updates arrive often (timer ticks, polls); only restart the shrink timer when the
        // target size actually changed, so a pending shrink is never postponed forever.
        guard target != lastTarget || shrinkTask == nil else { return }
        lastTarget = target
        shrinkTask?.cancel()
        shrinkTask = nil
        if grown != target {
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.shrinkTask = nil
                self.setPanelSize(self.hub.shapeSize)
            }
        }
    }

    private func setPanelSize(_ size: CGSize) {
        let frame = NSRect(x: (geometry.centerX - size.width / 2).rounded(),
                           y: geometry.screenTop - size.height,
                           width: size.width.rounded(),
                           height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }
}
