import AppKit
import Combine
import SwiftUI

/// Module 4: history of the last N text / URL / image copies (polls changeCount every 0.5 s).
@MainActor
final class ClipboardModule: ObservableObject, NotchModule {
    struct Settings: Codable, Equatable, Sendable {
        var maxItems = 50
        var ignorePasswords = true
    }

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let historyKey = "clipboard.history"
    static let settingsKey = "clipboard.settings"

    let id = "clipboard"
    let title = "Clipboard"
    let systemImage = "doc.on.clipboard"
    let panelHeight: CGFloat = 240

    @Published private(set) var history: ClipboardHistory
    @Published var query = ""
    @Published var settings: Settings {
        didSet {
            AppDefaults.encode(settings, to: defaults, key: Self.settingsKey)
            history.maxItems = settings.maxItems
            history.trim()
            save()
        }
    }

    private let defaults: UserDefaults
    private let notify: TransientSink
    private let pasteboard: NSPasteboard
    private var timer: Timer?

    init(defaults: UserDefaults, notify: @escaping TransientSink, pasteboard: NSPasteboard = .general) {
        self.defaults = defaults
        self.notify = notify
        self.pasteboard = pasteboard
        let s = AppDefaults.decode(Settings.self, from: defaults, key: Self.settingsKey) ?? Settings()
        settings = s
        var h = AppDefaults.decode(ClipboardHistory.self, from: defaults, key: Self.historyKey)
            ?? ClipboardHistory(maxItems: s.maxItems)
        h.dropOrphanImages()
        h.maxItems = s.maxItems
        history = h
    }

    func start() {
        guard timer == nil else { return }
        // Whatever is on the pasteboard at start was copied before we were watching.
        _ = history.ingest(changeCount: pasteboard.changeCount, content: nil, now: Date())
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        save()
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != history.lastChangeCount else { return }
        let types = pasteboard.types ?? []
        let concealed = types.contains(Self.concealedType)
        let content = concealed && settings.ignorePasswords ? nil : Self.read(pasteboard)
        if history.ingest(changeCount: count, content: content, concealed: concealed,
                          ignoreConcealed: settings.ignorePasswords, now: Date()) {
            save()
        }
    }

    static func read(_ pb: NSPasteboard) -> ClipContent? {
        let types = pb.types ?? []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first,
           types.contains(.URL) || types.contains(.fileURL) {
            return .url(url.isFileURL ? url.path : url.absoluteString)
        }
        if let s = pb.string(forType: .string) {
            if let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), !s.contains(" ") {
                return .url(url.absoluteString)
            }
            return .text(s)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type) {
                let size = NSImage(data: data)?.size ?? .zero
                return .image(data, label: "Image \(Int(size.width))×\(Int(size.height))")
            }
        }
        return nil
    }

    func copyBack(_ item: ClipItem) {
        guard let content = item.content else { return }
        pasteboard.clearContents()
        switch content {
        case .text(let s):
            pasteboard.setString(s, forType: .string)
        case .url(let s):
            pasteboard.setString(s, forType: .string)
            if let url = URL(string: s), url.scheme != nil { pasteboard.setString(url.absoluteString, forType: .URL) }
        case .image(let data, _):
            pasteboard.setData(data, forType: NSImage(data: data) != nil && data.starts(with: [0x89, 0x50]) ? .png : .tiff)
        }
        history.noteOwnWrite(changeCount: pasteboard.changeCount, itemID: item.id, now: Date())
        save()
        notify(Transient("Copied", systemImage: "doc.on.doc.fill", tint: .white))
    }

    func togglePin(_ item: ClipItem) {
        history.togglePin(item.id)
        save()
    }

    func remove(_ item: ClipItem) {
        history.remove(item.id)
        save()
    }

    func clear() {
        history.clearUnpinned()
        save()
    }

    private func save() {
        AppDefaults.encode(history, to: defaults, key: Self.historyKey)
    }

    var expandedView: AnyView { AnyView(ClipboardView(module: self)) }
    var settingsView: AnyView { AnyView(ClipboardSettingsView(module: self)) }
}

struct ClipboardView: View {
    @ObservedObject var module: ClipboardModule

    var body: some View {
        let items = module.history.filtered(module.query)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Palette.dim)
                TextField("Search", text: $module.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !module.query.isEmpty {
                    IconButton(systemImage: "xmark.circle.fill", size: 11, tint: Palette.dim) { module.query = "" }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))

            if items.isEmpty {
                Text(module.query.isEmpty ? "Copy some text, a link or an image." : "No matches.")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                ClipRow(item: item, now: context.date,
                                        copy: { module.copyBack(item) },
                                        pin: { module.togglePin(item) })
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

struct ClipRow: View {
    var item: ClipItem
    var now: Date
    var copy: () -> Void
    var pin: () -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var icon: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        }
    }

    private var age: String {
        now.timeIntervalSince(item.date) < 30 ? "now" : Self.formatter.localizedString(for: item.date, relativeTo: now)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: copy) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.dim)
                        .frame(width: 14)
                    Text(item.preview)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(age)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Palette.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to copy")
            IconButton(systemImage: item.pinned ? "pin.fill" : "pin", size: 10,
                       tint: item.pinned ? Palette.orange : Palette.dim,
                       help: item.pinned ? "Unpin" : "Pin (never ages out)", action: pin)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(item.pinned ? 0.07 : 0.03)))
    }
}

struct ClipboardSettingsView: View {
    @ObservedObject var module: ClipboardModule

    var body: some View {
        Stepper("Keep the last \(module.settings.maxItems) copies", value: $module.settings.maxItems, in: 10...200, step: 10)
        Toggle("Ignore passwords (skip org.nspasteboard.ConcealedType)", isOn: $module.settings.ignorePasswords)
        HStack {
            Text("Pinned items never age out. Images are kept in memory only.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Clear history") { module.clear() }
        }
    }
}
