import Charts
import Combine
import SwiftUI

/// Module 1: the v1 Pomodoro, plus a 7-day chart of focused minutes.
@MainActor
final class FocusModule: ObservableObject, NotchModule {
    let engine: PomodoroEngine
    private var cancellables = Set<AnyCancellable>()

    let id = "focus"
    let title = "Focus"
    let systemImage = "timer"
    let panelHeight: CGFloat = 180

    init(engine: PomodoroEngine) {
        self.engine = engine
        // Republish engine changes so the hub re-evaluates the collapsed bar.
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The engine owns its own wall-clock timer; nothing to start. Disabling the module only hides
    /// it (a running session keeps its end date and is resumed when shown again).
    func start() {}
    func stop() {}

    var collapsedPriority: Int {
        engine.isRunning ? CollapsedPriority.focusRunning : CollapsedPriority.focusPaused
    }

    var collapsedView: AnyView? {
        guard engine.isActive else { return nil }
        return AnyView(FocusCollapsedView(engine: engine))
    }

    var expandedView: AnyView { AnyView(FocusExpandedView(engine: engine)) }

    var settingsView: AnyView { AnyView(FocusSettingsView(engine: engine)) }
}

enum PhaseColors {
    static func color(_ phase: Phase) -> Color {
        switch phase {
        case .focus: return Palette.focus
        case .shortBreak: return Palette.green
        case .longBreak: return Palette.blue
        }
    }
}

/// Focused minutes per local day for the last `days` days (oldest first, today last).
struct DayMinutes: Identifiable, Equatable, Sendable {
    var day: Date
    var minutes: Double
    var id: Date { day }
}

enum FocusStats {
    static func lastDays(_ days: Int, history: [SessionRecord], now: Date, calendar: Calendar) -> [DayMinutes] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset -> DayMinutes? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let minutes = history
                .filter { $0.phase == .focus && $0.endedAt >= start && $0.endedAt < end }
                .reduce(0) { $0 + $1.minutes }
            return DayMinutes(day: start, minutes: minutes)
        }
    }
}

struct FocusCollapsedView: View {
    @ObservedObject var engine: PomodoroEngine

    var body: some View {
        let color = PhaseColors.color(engine.phase)
        WingsBar(wingWidth: 110) {
            Text(engine.timeString)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        } right: {
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.phase.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(color)
                    .lineLimit(1)
                ProgressBar(progress: engine.progress, color: color)
                    .frame(height: 3)
            }
            .frame(width: 80)
        }
    }
}

struct FocusExpandedView: View {
    @ObservedObject var engine: PomodoroEngine

    var body: some View {
        let color = PhaseColors.color(engine.phase)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.timeString)
                        .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(.white)
                    Text("\(engine.phase.label) · Session \(engine.sessionNumber) of \(engine.sessionsTotal)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color)
                }
                Spacer(minLength: 0)
                WeekChart(days: FocusStats.lastDays(7, history: engine.history, now: Date(), calendar: .current))
                    .frame(width: 150, height: 74)
            }
            HStack(spacing: 8) {
                Button(engine.isRunning ? "Pause" : "Start") { engine.toggle() }
                    .buttonStyle(PillButtonStyle(fill: color, prominent: true))
                Button("Skip") { engine.skip() }
                    .buttonStyle(PillButtonStyle(fill: .white, prominent: false))
                Button("Reset") { engine.reset() }
                    .buttonStyle(PillButtonStyle(fill: .white, prominent: false))
            }
            TodayRow(count: engine.todayFocusCount(),
                     minutes: engine.todayFocusMinutes(),
                     target: engine.sessionsTotal)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 7-day bar chart of focused minutes (SwiftUI Charts, a system framework).
struct WeekChart: View {
    var days: [DayMinutes]

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("7 days · \(Int(days.reduce(0) { $0 + $1.minutes }.rounded())) min")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Palette.dim)
            Chart(days) { day in
                BarMark(x: .value("Day", day.day, unit: .day),
                        y: .value("Minutes", day.minutes))
                    .foregroundStyle(Palette.focus.opacity(day.id == days.last?.id ? 1 : 0.6))
                    .cornerRadius(2)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .font(.system(size: 8))
                }
            }
        }
    }
}

/// "● ● ○ ○  🍅 × N today · M min focused"
struct TodayRow: View {
    static let maxDots = 12
    var count: Int
    var minutes: Int
    var target: Int

    var body: some View {
        let slots = min(Self.maxDots, max(count, target))
        let filled = min(count, Self.maxDots)
        HStack(spacing: 4) {
            ForEach(0..<slots, id: \.self) { i in
                Circle()
                    .fill(i < filled ? Palette.focus : Color.clear)
                    .overlay(Circle().stroke(Palette.focus.opacity(0.8), lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
            if count > Self.maxDots {
                Text("+\(count - Self.maxDots)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            Text("🍅 × \(count) today · \(minutes) min focused")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .padding(.leading, 4)
        }
    }
}

struct FocusSettingsView: View {
    @ObservedObject var engine: PomodoroEngine

    var body: some View {
        Stepper("Focus: \(engine.settings.focusMinutes) min",
                value: $engine.settings.focusMinutes, in: 1...120)
        Stepper("Short break: \(engine.settings.shortBreakMinutes) min",
                value: $engine.settings.shortBreakMinutes, in: 1...60)
        Stepper("Long break: \(engine.settings.longBreakMinutes) min",
                value: $engine.settings.longBreakMinutes, in: 1...90)
        Stepper("Sessions before long break: \(engine.settings.sessionsBeforeLongBreak)",
                value: $engine.settings.sessionsBeforeLongBreak, in: 1...12)
        Toggle("Sound at session end", isOn: $engine.settings.soundEnabled)
        Toggle("Auto-start next phase", isOn: $engine.settings.autoStartNext)
        Text("Notifications are requested the first time you start a session.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
