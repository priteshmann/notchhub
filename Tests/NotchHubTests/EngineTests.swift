import Foundation
@testable import NotchHub

// The Command Line Tools ship Swift Testing but not XCTest. The scenarios below are written
// once and run under XCTest when it is available, otherwise under Swift Testing.

/// Controllable wall clock.
@MainActor
final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
enum EngineScenarios {
    static func istCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return cal
    }

    static func freshDefaults() -> UserDefaults {
        let name = "NotchHubTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static func makeEngine(_ clock: TestClock, defaults: UserDefaults? = nil) -> PomodoroEngine {
        PomodoroEngine(defaults: defaults ?? freshDefaults(),
                       calendar: istCalendar(),
                       now: { clock.date },
                       runsTimer: false)
    }

    /// Runs the current phase to its end using the wall clock.
    static func runPhaseToEnd(_ engine: PomodoroEngine, _ clock: TestClock) {
        engine.start()
        clock.advance(engine.plannedDuration + 1)
        engine.tick()
    }

    /// 4 focus sessions → long break → focus with the cycle reset.
    static func phaseSequencing(_ check: (Bool, String) -> Void) {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let engine = makeEngine(clock)
        check(engine.phase == .focus && engine.sessionNumber == 1, "starts on focus, session 1")

        var seen: [Phase] = []
        for _ in 0..<8 {
            runPhaseToEnd(engine, clock)
            seen.append(engine.phase)
        }
        let expected: [Phase] = [.shortBreak, .focus, .shortBreak, .focus,
                                 .shortBreak, .focus, .longBreak, .focus]
        check(seen == expected, "sequence was \(seen)")
        check(engine.completedFocusInCycle == 0, "cycle resets after long break")
        check(engine.history.filter { $0.phase == .focus }.count == 4, "4 focus sessions recorded")
        check(engine.isRunning == false, "auto-start off: next phase waits paused")
        check(engine.remaining == engine.settings.duration(for: .focus), "next phase at full duration")
    }

    /// Today's count excludes sessions finished before local midnight.
    static func todayRollover(_ check: (Bool, String) -> Void) {
        let cal = istCalendar()
        let lateEvening = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 0))!
        let clock = TestClock(lateEvening)
        let engine = makeEngine(clock)

        runPhaseToEnd(engine, clock)          // focus ends 23:25
        check(engine.todayFocusCount() == 1, "one session today before midnight")
        check(engine.todayFocusMinutes() == 25, "25 minutes before midnight")

        clock.advance(40 * 60)                // now 00:05 next day
        check(engine.todayFocusCount() == 0, "count rolls over at local midnight")
        check(engine.todayFocusMinutes() == 0, "minutes roll over at local midnight")

        engine.skip()                         // skip the break, back to focus
        runPhaseToEnd(engine, clock)
        check(engine.todayFocusCount() == 1, "new day counts its own session")
    }

    /// A relaunch resumes from the persisted END timestamp, not elapsed ticks.
    static func resumeFromPersistedEnd(_ check: (Bool, String) -> Void) {
        let defaults = freshDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = makeEngine(clock, defaults: defaults)
        first.start()

        // "Quit", 10 minutes pass, relaunch.
        clock.advance(600)
        let second = makeEngine(clock, defaults: defaults)
        check(second.isRunning, "still running after relaunch")
        check(second.phase == .focus, "same phase after relaunch")
        check(abs(second.remaining - (25 * 60 - 600)) < 0.001, "remaining = end - now (\(second.remaining))")

        // Relaunch after the end passed: phase completes with the stored end time.
        clock.advance(30 * 60)
        let third = makeEngine(clock, defaults: defaults)
        check(third.phase == .shortBreak, "finished focus while closed → short break")
        check(third.isRunning == false, "next phase paused (auto-start off)")
        let last = third.history.last
        check(last?.phase == .focus, "focus recorded")
        check(last?.endedAt == Date(timeIntervalSince1970: 1_800_000_000 + 25 * 60),
              "recorded end = persisted end timestamp")

        // Paused state survives too.
        third.start()
        clock.advance(60)
        third.tick()
        third.pause()
        clock.advance(3600)
        let fourth = makeEngine(clock, defaults: defaults)
        check(!fourth.isRunning && abs(fourth.remaining - 4 * 60) < 0.001, "paused remaining kept")
    }

    static func historyCap(_ check: (Bool, String) -> Void) {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let engine = makeEngine(clock)
        for _ in 0..<(PomodoroEngine.historyCap / 2 + 5) {
            runPhaseToEnd(engine, clock)
        }
        check(engine.history.count <= PomodoroEngine.historyCap, "history capped")
    }
}

#if canImport(XCTest)
import XCTest

@MainActor
final class EngineTests: XCTestCase {
    private func check(_ ok: Bool, _ msg: String) { XCTAssertTrue(ok, msg) }
    func testPhaseSequencing() { EngineScenarios.phaseSequencing(check) }
    func testTodayRolloverAtLocalMidnight() { EngineScenarios.todayRollover(check) }
    func testResumeFromPersistedEndTime() { EngineScenarios.resumeFromPersistedEnd(check) }
    func testHistoryCap() { EngineScenarios.historyCap(check) }
}

#elseif canImport(Testing)
import Testing

@MainActor
@Suite struct EngineTests {
    private func check(_ ok: Bool, _ msg: String) { #expect(ok, Comment(rawValue: msg)) }
    @Test func phaseSequencing() { EngineScenarios.phaseSequencing(check) }
    @Test func todayRolloverAtLocalMidnight() { EngineScenarios.todayRollover(check) }
    @Test func resumeFromPersistedEndTime() { EngineScenarios.resumeFromPersistedEnd(check) }
    @Test func historyCap() { EngineScenarios.historyCap(check) }
}
#endif
