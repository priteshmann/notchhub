import Foundation

/// Tint of a transient overlay. Kept as an enum so the queue stays UI-free and testable.
enum TransientTint: String, Sendable, Equatable {
    case white, green, orange, red, blue
}

/// A short-lived collapsed overlay ("Charging · 64%", "Copied", "AirDrop sent").
struct Transient: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var systemImage: String
    var tint: TransientTint
    /// Optional 0...1 level drawn as an animated fill (battery transients).
    var fill: Double?

    init(_ text: String, systemImage: String, tint: TransientTint = .white, fill: Double? = nil) {
        self.id = UUID()
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.fill = fill
    }
}

/// FIFO of transients. Only the head is on screen; it is shown for `duration` seconds from the
/// moment it reaches the head, then the next one takes over. Time is always passed in, so tests
/// drive it with an injected clock.
struct TransientQueue: Sendable {
    static let defaultDuration: TimeInterval = 2.5
    static let maxPending = 6

    var duration: TimeInterval = TransientQueue.defaultDuration
    private var pending: [Transient] = []
    /// When the current head started showing.
    private var headShownAt: Date?

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    mutating func enqueue(_ transient: Transient, now: Date) {
        if pending.count >= Self.maxPending {
            // Drop the oldest waiting item, never the one on screen.
            pending.remove(at: 1)
        }
        pending.append(transient)
        if pending.count == 1 { headShownAt = now }
    }

    /// The transient on screen at `now`, after dropping every expired head.
    mutating func current(now: Date) -> Transient? {
        while let shownAt = headShownAt, !pending.isEmpty, shownAt.addingTimeInterval(duration) <= now {
            pending.removeFirst()
            // The next item starts exactly when the previous one expired.
            headShownAt = pending.isEmpty ? nil : shownAt.addingTimeInterval(duration)
        }
        return pending.first
    }

    /// When the current head expires (nil when empty), so the owner can schedule one wake-up.
    var nextExpiry: Date? {
        guard !pending.isEmpty, let shownAt = headShownAt else { return nil }
        return shownAt.addingTimeInterval(duration)
    }

    mutating func removeAll() {
        pending.removeAll()
        headShownAt = nil
    }
}
