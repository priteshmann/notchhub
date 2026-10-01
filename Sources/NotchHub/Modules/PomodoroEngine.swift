import Foundation
import Combine

enum Phase: String, Codable, Sendable {
    case focus, shortBreak, longBreak

    var label: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long break"
        }
    }
}

struct PomodoroSettings: Codable, Equatable, Sendable {
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    var sessionsBeforeLongBreak: Int = 4
    var soundEnabled: Bool = true
    var autoStartNext: Bool = false
    var launchAtLogin: Bool = false

    func minutes(for phase: Phase) -> Int {
        switch phase {
        case .focus: return focusMinutes
        case .shortBreak: return shortBreakMinutes
        case .longBreak: return longBreakMinutes
        }
    }

    func duration(for phase: Phase) -> TimeInterval {
        TimeInterval(max(1, minutes(for: phase)) * 60)
    }
}

/// One completed session, as stored in UserDefaults under `history`.
struct SessionRecord: Codable, Equatable, Sendable {
    var startedAt: Date
    var endedAt: Date
    var phase: Phase
    var minutes: Double
}

/// The in-flight session. Running sessions store their END timestamp (wall clock),
/// never elapsed seconds, so a relaunch resumes exactly.
struct InFlightSession: Codable, Equatable, Sendable {
    var phase: Phase
    var completedFocusInCycle: Int
    var isRunning: Bool
    var isActive: Bool
    var endDate: Date?
    var pausedRemaining: TimeInterval
    var plannedDuration: TimeInterval
    var startedAt: Date?
}

@MainActor
final class PomodoroEngine: ObservableObject {
    static let historyCap = 2000

    enum Keys {
        static let settings = "settings"
        static let history = "history"
        static let inFlight = "inFlight"
    }

    @Published private(set) var phase: Phase = .focus
    /// Focus sessions finished in the current cycle (resets after the long break).
    @Published private(set) var completedFocusInCycle = 0
    @Published private(set) var isRunning = false
    /// True from the first Start until Reset: the collapsed bar shows its wings.
    @Published private(set) var isActive = false
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var plannedDuration: TimeInterval
    @Published private(set) var history: [SessionRecord] = []
    /// Incremented whenever a phase completes live; the view flashes on change.
    @Published private(set) var flashTrigger = 0
    @Published var settings: PomodoroSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    /// (finished phase, next phase). Called only for live completions.
    var onPhaseComplete: ((Phase, Phase) -> Void)?

    private var endDate: Date?
    private var startedAt: Date?
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private var timer: Timer?

    init(defaults: UserDefaults = .standard,
         calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() },
         runsTimer: Bool = true) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        let loaded = Self.decode(PomodoroSettings.self, from: defaults, key: Keys.settings) ?? PomodoroSettings()
        self.settings = loaded
        self.plannedDuration = loaded.duration(for: .focus)
        self.remaining = loaded.duration(for: .focus)
        self.history = Self.decode([SessionRecord].self, from: defaults, key: Keys.history) ?? []
        if let inFlight = Self.decode(InFlightSession.self, from: defaults, key: Keys.inFlight) {
            restore(inFlight)
        }
        if runsTimer { startTimer() }
    }

    // MARK: - Derived values

    var progress: Double {
        guard plannedDuration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / plannedDuration))
    }

    var timeString: String { Self.format(remaining) }

    var sessionsTotal: Int { max(1, settings.sessionsBeforeLongBreak) }

    /// "Session k of n": focus counts the one in progress, breaks the one just finished.
    var sessionNumber: Int {
        switch phase {
        case .focus: return min(completedFocusInCycle + 1, sessionsTotal)
        case .shortBreak, .longBreak: return max(1, min(completedFocusInCycle, sessionsTotal))
        }
    }

    func todaysFocusSessions(at date: Date? = nil) -> [SessionRecord] {
        let reference = date ?? now()
        let start = calendar.startOfDay(for: reference)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return history.filter { $0.phase == .focus && $0.endedAt >= start && $0.endedAt < end }
    }

    func todayFocusCount(at date: Date? = nil) -> Int { todaysFocusSessions(at: date).count }

    func todayFocusMinutes(at date: Date? = nil) -> Int {
        Int(todaysFocusSessions(at: date).reduce(0) { $0 + $1.minutes }.rounded())
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Commands

    func start() {
        guard !isRunning else { return }
        let n = now()
        if remaining <= 0 { remaining = plannedDuration }
        endDate = n.addingTimeInterval(remaining)
        if startedAt == nil { startedAt = n }
        isRunning = true
        isActive = true
        persist()
    }

    func pause() {
        guard isRunning, let end = endDate else { return }
        remaining = max(0, end.timeIntervalSince(now()))
        endDate = nil
        isRunning = false
        persist()
    }

    func toggle() { isRunning ? pause() : start() }

    /// Jump to the next phase without recording the current one.
    func skip() {
        let wasRunning = isRunning
        isRunning = false
        advanceSequence()
        isActive = true
        if wasRunning { start() } else { persist() }
    }

    func reset() {
        isRunning = false
        endDate = nil
        startedAt = nil
        phase = .focus
        completedFocusInCycle = 0
        plannedDuration = settings.duration(for: .focus)
        remaining = plannedDuration
        isActive = false
        persist()
    }

    /// Republish remaining = end - now; complete the phase when the end has passed.
    func tick() {
        guard isRunning, let end = endDate else { return }
        let n = now()
        if n >= end {
            completePhase(endedAt: end, live: true)
        } else {
            remaining = end.timeIntervalSince(n)
        }
    }

    // MARK: - Internals

    private func startTimer() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func restore(_ s: InFlightSession) {
        phase = s.phase
        completedFocusInCycle = s.completedFocusInCycle
        plannedDuration = s.plannedDuration > 0 ? s.plannedDuration : settings.duration(for: s.phase)
        isActive = s.isActive
        startedAt = s.startedAt
        if s.isRunning, let end = s.endDate {
            endDate = end
            isRunning = true
            let n = now()
            if n >= end {
                completePhase(endedAt: end, live: false)
            } else {
                remaining = end.timeIntervalSince(n)
            }
        } else {
            isRunning = false
            endDate = nil
            remaining = s.pausedRemaining
        }
    }

    private func completePhase(endedAt end: Date, live: Bool) {
        let finished = phase
        let record = SessionRecord(
            startedAt: startedAt ?? end.addingTimeInterval(-plannedDuration),
            endedAt: end,
            phase: finished,
            minutes: plannedDuration / 60
        )
        appendHistory(record)
        isRunning = false
        advanceSequence()
        isActive = true
        if settings.autoStartNext {
            start()
        } else {
            persist()
        }
        if live {
            flashTrigger += 1
            onPhaseComplete?(finished, phase)
        }
    }

    private func advanceSequence() {
        switch phase {
        case .focus:
            completedFocusInCycle += 1
            phase = completedFocusInCycle >= sessionsTotal ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            completedFocusInCycle = 0
            phase = .focus
        }
        plannedDuration = settings.duration(for: phase)
        remaining = plannedDuration
        endDate = nil
        startedAt = nil
    }

    private func appendHistory(_ record: SessionRecord) {
        history.append(record)
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
        Self.encode(history, to: defaults, key: Keys.history)
    }

    private func settingsChanged(from old: PomodoroSettings) {
        Self.encode(settings, to: defaults, key: Keys.settings)
        // An untouched, not-running phase picks up a new length immediately.
        if !isRunning, remaining == old.duration(for: phase) {
            plannedDuration = settings.duration(for: phase)
            remaining = plannedDuration
            persist()
        }
    }

    private func persist() {
        let s = InFlightSession(
            phase: phase,
            completedFocusInCycle: completedFocusInCycle,
            isRunning: isRunning,
            isActive: isActive,
            endDate: isRunning ? endDate : nil,
            pausedRemaining: remaining,
            plannedDuration: plannedDuration,
            startedAt: startedAt
        )
        Self.encode(s, to: defaults, key: Keys.inFlight)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
