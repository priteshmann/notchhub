import AppKit
import Combine
import SwiftUI

/// Module 3: a file shelf. Drop files on the notch, drag them out to any app, AirDrop them.
@MainActor
final class ShelfModule: ObservableObject, NotchModule {
    let id = "shelf"
    let title = "Shelf"
    let systemImage = "tray.full"
    let panelHeight: CGFloat = 200

    @Published private(set) var items: [ShelfItem] = []

    private let defaults: UserDefaults
    private let notify: TransientSink
    /// Tells the hub a drag-out is in progress so the panel stays open.
    private let dragOut: (Bool) -> Void
    private var icons: [String: NSImage] = [:]
    private var airDropDelegate: AirDropDelegate?

    init(defaults: UserDefaults, notify: @escaping TransientSink, dragOut: @escaping (Bool) -> Void) {
        self.defaults = defaults
        self.notify = notify
        self.dragOut = dragOut
        items = ShelfStore.load(from: defaults)
        ShelfStore.save(items, to: defaults)
    }

    func start() {}
    func stop() {}

    func url(for item: ShelfItem) -> URL {
        if let resolved = ShelfStore.resolve(item.bookmark) {
            _ = resolved.url.startAccessingSecurityScopedResource()
            return resolved.url
        }
        return URL(fileURLWithPath: item.path)
    }

    func icon(for item: ShelfItem) -> NSImage {
        if let cached = icons[item.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.path)
        icons[item.path] = image
        return image
    }

    func add(_ urls: [URL]) {
        var added = 0
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            if let item = try? ShelfStore.makeItem(for: url) {
                items.append(item)
                added += 1
            }
        }
        guard added > 0 else { return }
        ShelfStore.save(items, to: defaults)
        notify(Transient(added == 1 ? "Added to Shelf" : "\(added) files on Shelf",
                         systemImage: "tray.and.arrow.down.fill", tint: .blue))
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        ShelfStore.save(items, to: defaults)
    }

    func clear() {
        items.removeAll()
        ShelfStore.save(items, to: defaults)
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(url(for: item))
    }

    func dragBegan() { dragOut(true) }
    func dragEnded() { dragOut(false) }

    func airDrop() {
        let urls = items.map(url(for:))
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        guard service.canPerform(withItems: urls) else {
            notify(Transient("AirDrop unavailable", systemImage: "wifi.exclamationmark", tint: .orange))
            return
        }
        let delegate = AirDropDelegate { [weak self] sent in
            self?.notify(sent ? Transient("AirDrop sent", systemImage: "airplayaudio", tint: .blue)
                              : Transient("AirDrop cancelled", systemImage: "xmark", tint: .white))
            self?.airDropDelegate = nil
        }
        airDropDelegate = delegate
        service.delegate = delegate
        service.perform(withItems: urls)
    }

    var expandedView: AnyView { AnyView(ShelfView(module: self)) }
    var settingsView: AnyView {
        AnyView(Text("Drop files on the notch or the Shelf tab. Drag a file out to any app, ⌘-click to remove it, double-click to open it.")
            .font(.caption).foregroundColor(.secondary))
    }
}

final class AirDropDelegate: NSObject, NSSharingServiceDelegate {
    private let done: @MainActor (Bool) -> Void

    init(done: @escaping @MainActor (Bool) -> Void) { self.done = done }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { done(true) }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        MainActor.assumeIsolated { done(false) }
    }
}

struct ShelfView: View {
    @ObservedObject var module: ShelfModule

    private let columns = [GridItem(.adaptive(minimum: 66, maximum: 80), spacing: 6)]

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(module.items.isEmpty ? "Shelf" : "\(module.items.count) item\(module.items.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button("AirDrop") { module.airDrop() }
                    .buttonStyle(PillButtonStyle(fill: Palette.blue, prominent: false))
                    .disabled(module.items.isEmpty)
                Button("Clear") { module.clear() }
                    .buttonStyle(PillButtonStyle(fill: .white, prominent: false))
                    .disabled(module.items.isEmpty)
            }
            if module.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22))
                    Text("Drop files here or onto the notch.")
                        .font(.system(size: 11))
                }
                .foregroundColor(Palette.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(module.items) { item in
                            ShelfTile(module: module, item: item)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

struct ShelfTile: View {
    @ObservedObject var module: ShelfModule
    var item: ShelfItem

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: module.icon(for: item))
                .resizable()
                .frame(width: 40, height: 40)
            Text(item.name)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: 66, height: 72)
        .overlay(
            FileDragSource(
                url: { module.url(for: item) },
                image: { module.icon(for: item) },
                onRemove: { module.remove(item) },
                onOpen: { module.open(item) },
                onDragBegan: { module.dragBegan() },
                onDragEnded: { module.dragEnded() })
        )
        .help("\(item.path)\nDrag out · ⌘-click to remove · double-click to open")
    }
}

/// AppKit drag source over a tile: begins a file drag with the URL on the pasteboard and reports
/// when the session ends (SwiftUI's onDrag has no end callback, and the panel must stay open
/// until the drop lands).
struct FileDragSource: NSViewRepresentable {
    var url: () -> URL
    var image: () -> NSImage
    var onRemove: () -> Void
    var onOpen: () -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.config = self
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.config = self
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var config: FileDragSource?
        private var downEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            downEvent = event
            if event.modifierFlags.contains(.command) {
                downEvent = nil
                config?.onRemove()
            } else if event.clickCount == 2 {
                downEvent = nil
                config?.onOpen()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, let config else { return }
            let a = down.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            downEvent = nil
            let item = NSDraggingItem(pasteboardWriter: config.url() as NSURL)
            let side: CGFloat = 40
            let origin = convert(a, from: nil)
            item.setDraggingFrame(NSRect(x: origin.x - side / 2, y: origin.y - side / 2, width: side, height: side),
                                  contents: config.image())
            beginDraggingSession(with: [item], event: down, source: self)
        }

        override func mouseUp(with event: NSEvent) { downEvent = nil }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            config?.onDragBegan()
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            config?.onDragEnded()
        }
    }
}
