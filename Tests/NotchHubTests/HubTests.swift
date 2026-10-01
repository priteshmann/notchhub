#if canImport(Testing)
import Foundation
import Testing
@testable import NotchHub

private func freshDefaults() -> UserDefaults {
    let name = "NotchHubTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct ClipboardDedupeTests {
    @Test func sameChangeCountTwiceIsOneEntry() {
        var h = ClipboardHistory()
        let v1 = h.ingest(changeCount: 7, content: .text("hello"), now: t0)
        #expect(v1)
        let v2 = h.ingest(changeCount: 7, content: .text("hello"), now: t0.addingTimeInterval(1))
        #expect(!v2)
        let v3 = h.ingest(changeCount: 7, content: .text("different"), now: t0.addingTimeInterval(2))
        #expect(!v3)
        #expect(h.items.count == 1)
    }

    @Test func sameTextTwiceInARowIsOneEntry() {
        var h = ClipboardHistory()
        h.ingest(changeCount: 1, content: .text("same"), now: t0)
        h.ingest(changeCount: 2, content: .text("same"), now: t0.addingTimeInterval(5))
        #expect(h.items.count == 1)
        #expect(h.items[0].date == t0.addingTimeInterval(5))
        h.ingest(changeCount: 3, content: .text("other"), now: t0.addingTimeInterval(6))
        #expect(h.items.map(\.text) == ["other", "same"])
    }

    @Test func recopiedOlderItemMovesUpWithoutDuplicate() {
        var h = ClipboardHistory()
        h.ingest(changeCount: 1, content: .text("a"), now: t0)
        h.ingest(changeCount: 2, content: .url("https://example.com"), now: t0)
        h.ingest(changeCount: 3, content: .text("a"), now: t0)
        #expect(h.items.map(\.text) == ["a", "https://example.com"])
    }

    @Test func concealedIsSkippedWhenIgnoringPasswords() {
        var h = ClipboardHistory()
        let v4 = h.ingest(changeCount: 1, content: .text("hunter2"), concealed: true, ignoreConcealed: true, now: t0)
        #expect(!v4)
        #expect(h.items.isEmpty)
        let v5 = h.ingest(changeCount: 2, content: .text("hunter2"), concealed: true, ignoreConcealed: false, now: t0)
        #expect(v5)
    }

    @Test func pinnedNeverAgeOut() {
        var h = ClipboardHistory(maxItems: 3)
        h.ingest(changeCount: 0, content: .text("keep"), now: t0)
        h.togglePin(h.items[0].id)
        for i in 1...10 { h.ingest(changeCount: i, content: .text("n\(i)"), now: t0) }
        #expect(h.items.filter { !$0.pinned }.count == 3)
        #expect(h.items.contains { $0.text == "keep" && $0.pinned })
        #expect(h.filtered("").first?.text == "keep")
    }

    @Test func ownWriteIsNotRecordedAgain() {
        var h = ClipboardHistory()
        h.ingest(changeCount: 1, content: .text("a"), now: t0)
        h.ingest(changeCount: 2, content: .text("b"), now: t0)
        let a = h.items[1].id
        h.noteOwnWrite(changeCount: 3, itemID: a, now: t0)
        let v6 = h.ingest(changeCount: 3, content: .text("a"), now: t0)
        #expect(!v6)
        #expect(h.items.map(\.text) == ["a", "b"])
    }

    @Test func previewIsOneLineSixtyChars() {
        let p = ClipItem.preview("line one\n\n   line two " + String(repeating: "x", count: 100))
        #expect(!p.contains("\n"))
        #expect(p.count == 60)
        #expect(p.hasPrefix("line one line two"))
    }
}

@Suite struct ShelfBookmarkTests {
    @Test func bookmarkRoundTripThroughDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchHubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.txt")
        try Data("hi".utf8).write(to: file)

        let defaults = freshDefaults()
        let item = try ShelfStore.makeItem(for: file)
        ShelfStore.save([item], to: defaults)

        let loaded = ShelfStore.load(from: defaults)
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == item.id)
        #expect(loaded.first?.name == "report.txt")
        let first = try #require(loaded.first)
        let resolved = try #require(ShelfStore.resolve(first.bookmark))
        #expect(resolved.url.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)

        // The bookmark follows a rename; load() refreshes the stored path.
        let moved = dir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        let afterMove = ShelfStore.load(from: defaults)
        #expect(afterMove.first?.name == "renamed.txt")

        // A deleted file is dropped on load.
        try FileManager.default.removeItem(at: moved)
        #expect(ShelfStore.load(from: defaults).isEmpty)
    }
}

@Suite struct TransientQueueTests {
    @Test func showsInOrderAndExpires() {
        var clock = t0
        var q = TransientQueue()
        let a = Transient("A", systemImage: "a.circle")
        let b = Transient("B", systemImage: "b.circle")
        q.enqueue(a, now: clock)
        clock += 1
        q.enqueue(b, now: clock)
        let v7 = q.current(now: clock)
        #expect(v7 == a)
        clock = t0.addingTimeInterval(2.49)
        let v8 = q.current(now: clock)
        #expect(v8 == a)
        clock = t0.addingTimeInterval(2.5)
        let started = q.current(now: clock)
        #expect(started == b)                          // B starts when A expires, not when queued
        #expect(q.nextExpiry == t0.addingTimeInterval(5.0))
        clock = t0.addingTimeInterval(4.99)
        let v9 = q.current(now: clock)
        #expect(v9 == b)
        clock = t0.addingTimeInterval(5.0)
        let v10 = q.current(now: clock)
        #expect(v10 == nil)
        #expect(q.isEmpty)
    }

    @Test func longGapExpiresEverything() {
        var q = TransientQueue()
        q.enqueue(Transient("A", systemImage: "a"), now: t0)
        q.enqueue(Transient("B", systemImage: "b"), now: t0)
        q.enqueue(Transient("C", systemImage: "c"), now: t0)
        let v11 = q.current(now: t0.addingTimeInterval(60))
        #expect(v11 == nil)
    }

    @Test func newItemAfterIdleStartsFresh() {
        var q = TransientQueue()
        q.enqueue(Transient("A", systemImage: "a"), now: t0)
        let v12 = q.current(now: t0.addingTimeInterval(10))
        #expect(v12 == nil)
        let b = Transient("B", systemImage: "b")
        q.enqueue(b, now: t0.addingTimeInterval(10))
        let v13 = q.current(now: t0.addingTimeInterval(12))
        #expect(v13 == b)
        let v14 = q.current(now: t0.addingTimeInterval(12.5))
        #expect(v14 == nil)
    }

    @Test func capDropsOldestWaitingNotTheVisibleOne() {
        var q = TransientQueue()
        let first = Transient("first", systemImage: "1")
        q.enqueue(first, now: t0)
        for i in 0..<10 { q.enqueue(Transient("n\(i)", systemImage: "x"), now: t0) }
        #expect(q.count == TransientQueue.maxPending)
        let v15 = q.current(now: t0)
        #expect(v15 == first)
    }
}

@Suite struct ModuleLogicTests {
    @Test func meetingLinks() {
        #expect(MeetingLink.find(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123456789?pwd=abc."])?.absoluteString
                == "https://us02web.zoom.us/j/123456789?pwd=abc")
        #expect(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.host == "meet.google.com")
        #expect(MeetingLink.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0>"]) != nil)
        #expect(MeetingLink.find(in: ["https://example.com/j/1", "no link"]) == nil)
    }

    @Test func calendarHeadline() {
        func ev(_ title: String, _ startMin: Double, _ endMin: Double, allDay: Bool = false) -> DayEvent {
            DayEvent(id: title, title: title, start: t0.addingTimeInterval(startMin * 60),
                     end: t0.addingTimeInterval(endMin * 60), isAllDay: allDay, color: [1, 1, 1], joinURL: nil)
        }
        #expect(CalendarText.headline([ev("Standup", 12, 27)], now: t0) == "Standup in 12m")
        #expect(CalendarText.headline([ev("Review", 65, 90)], now: t0) == "Review in 1h 5m")
        #expect(CalendarText.headline([ev("Sync", -5, 10)], now: t0) == "Sync now")
        #expect(CalendarText.headline([ev("Holiday", -600, 800, allDay: true), ev("Old", -60, -30)], now: t0) == nil)
    }

    @Test func batteryTransients() {
        var tr = BatteryTransitions()
        let v16 = tr.update(BatterySnapshot(percent: 64, onAC: true, charging: true, minutesRemaining: nil))
        #expect(v16.isEmpty)
        let unplug = tr.update(BatterySnapshot(percent: 64, onAC: false, charging: false, minutesRemaining: 200))
        #expect(unplug.map(\.text) == ["On battery · 64%"])
        let v17 = tr.update(BatterySnapshot(percent: 20, onAC: false, charging: false, minutesRemaining: 50))
        #expect(v17.map(\.text)
                == ["Low battery · 20%"])
        let v18 = tr.update(BatterySnapshot(percent: 19, onAC: false, charging: false, minutesRemaining: 50))
        #expect(v18.isEmpty)
        let v19 = tr.update(BatterySnapshot(percent: 10, onAC: false, charging: false, minutesRemaining: 20))
        #expect(v19.count == 1)
        let plug = tr.update(BatterySnapshot(percent: 10, onAC: true, charging: true, minutesRemaining: 90))
        #expect(plug.map(\.text) == ["Charging · 10%"])
    }
}
#endif
