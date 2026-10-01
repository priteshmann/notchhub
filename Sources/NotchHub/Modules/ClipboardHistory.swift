import Foundation

enum ClipKind: String, Codable, Sendable {
    case text, url, image
}

/// What was read from the pasteboard.
enum ClipContent: Equatable, Sendable {
    case text(String)
    case url(String)
    /// Image bytes (PNG or TIFF) + a short label such as "Image 640×480".
    case image(Data, label: String)
}

struct ClipItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: ClipKind
    /// The text or URL; for images, a label.
    var text: String
    var date: Date
    var pinned = false
    /// Images live in memory only (not persisted to UserDefaults).
    var imageData: Data?

    enum CodingKeys: String, CodingKey { case id, kind, text, date, pinned }

    init(content: ClipContent, date: Date) {
        self.date = date
        switch content {
        case .text(let s): kind = .text; text = s
        case .url(let s): kind = .url; text = s
        case .image(let data, let label): kind = .image; text = label; imageData = data
        }
    }

    var content: ClipContent? {
        switch kind {
        case .text: return .text(text)
        case .url: return .url(text)
        case .image: return imageData.map { .image($0, label: text) }
        }
    }

    func matches(_ c: ClipContent) -> Bool {
        switch c {
        case .text(let s): return kind == .text && text == s
        case .url(let s): return kind == .url && text == s
        case .image(let data, _): return kind == .image && imageData == data
        }
    }

    /// One line, whitespace collapsed, at most 60 characters.
    var preview: String { Self.preview(text) }

    static func preview(_ s: String, limit: Int = 60) -> String {
        let oneLine = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "…" : oneLine
    }
}

/// Pure clipboard history: dedupe, pinning, aging. No pasteboard access, so it is testable.
struct ClipboardHistory: Codable, Equatable, Sendable {
    var items: [ClipItem] = []
    var maxItems = 50
    /// Last pasteboard changeCount seen (not persisted: it resets every login).
    private(set) var lastChangeCount: Int?

    enum CodingKeys: String, CodingKey { case items, maxItems }

    init(maxItems: Int = 50) { self.maxItems = maxItems }

    /// Returns true when a new entry was added.
    @discardableResult
    mutating func ingest(changeCount: Int, content: ClipContent?, concealed: Bool = false,
                         ignoreConcealed: Bool = true, now: Date) -> Bool {
        guard changeCount != lastChangeCount else { return false }  // same change seen twice
        lastChangeCount = changeCount
        guard let content else { return false }
        if concealed && ignoreConcealed { return false }
        if case .text(let s) = content, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }

        if let first = items.first, first.matches(content) {
            items[0].date = now                                      // same content again: one entry
            return false
        }
        var item = ClipItem(content: content, date: now)
        if let index = items.firstIndex(where: { $0.matches(content) }) {
            item.pinned = items[index].pinned                        // re-copied older item moves up
            item.id = items[index].id
            items.remove(at: index)
        }
        items.insert(item, at: 0)
        trim()
        return true
    }

    /// The app itself wrote to the pasteboard (copy back): remember the count so the next poll
    /// does not record it again, and move the item to the top.
    mutating func noteOwnWrite(changeCount: Int, itemID: UUID, now: Date) {
        lastChangeCount = changeCount
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = items.remove(at: index)
        item.date = now
        items.insert(item, at: 0)
    }

    mutating func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        trim()
    }

    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    mutating func clearUnpinned() { items.removeAll { !$0.pinned } }

    /// Pinned items never age out; the oldest unpinned ones go beyond `maxItems`.
    mutating func trim() {
        var unpinned = 0
        items = items.filter { item in
            if item.pinned { return true }
            unpinned += 1
            return unpinned <= max(1, maxItems)
        }
    }

    func filtered(_ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? items : items.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }

    /// Drops image items whose bytes were not persisted.
    mutating func dropOrphanImages() { items.removeAll { $0.kind == .image && $0.imageData == nil } }
}
