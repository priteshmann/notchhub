import Foundation

/// One file on the Shelf: a bookmark (security-scoped when the system allows it) plus display data.
struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var bookmark: Data
    var name: String
    /// Path at the time of the last save (display + dedupe; the bookmark is the source of truth).
    var path: String
}

/// Bookmark + UserDefaults persistence for the Shelf. Pure functions so tests can round-trip.
enum ShelfStore {
    static let key = "shelf.items"

    /// Security-scoped bookmark when possible, plain bookmark otherwise (both survive renames/moves).
    static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    /// Resolved URL + whether the bookmark should be refreshed. nil when the file is gone.
    static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        return nil
    }

    static func makeItem(for url: URL) throws -> ShelfItem {
        ShelfItem(bookmark: try makeBookmark(for: url), name: url.lastPathComponent, path: url.path)
    }

    static func save(_ items: [ShelfItem], to defaults: UserDefaults) {
        AppDefaults.encode(items, to: defaults, key: key)
    }

    /// Loads items, refreshing stale bookmarks and dropping files that no longer exist.
    static func load(from defaults: UserDefaults) -> [ShelfItem] {
        let stored = AppDefaults.decode([ShelfItem].self, from: defaults, key: key) ?? []
        return stored.compactMap { item in
            guard let resolved = resolve(item.bookmark),
                  FileManager.default.fileExists(atPath: resolved.url.path) else { return nil }
            var fresh = item
            fresh.path = resolved.url.path
            fresh.name = resolved.url.lastPathComponent
            if resolved.stale, let data = try? makeBookmark(for: resolved.url) { fresh.bookmark = data }
            return fresh
        }
    }
}
