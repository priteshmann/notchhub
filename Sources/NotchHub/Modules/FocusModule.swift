import Combine
import SwiftUI

/// Module 1: the v1 Pomodoro, plus a GitHub-style heatmap of a year of focused minutes.
@MainActor
final class FocusModule: ObservableObject, NotchModule {
    let engine: PomodoroEngine
    private var cancellables = Set<AnyCancellable>()

    let id = "focus"
    let title = "Focus"
    let systemImage = "timer"
    let panelHeight: CGFloat = 210
    let panelWidth: CGFloat = FocusHeatmapView.panelWidth

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.timeString)
                        .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(.white)
                    Text("\(engine.phase.label) · Session \(engine.sessionNumber) of \(engine.sessionsTotal)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(engine.isRunning ? "Pause" : "Start") { engine.toggle() }
                        .buttonStyle(PillButtonStyle(fill: color, prominent: true))
                    Button("Skip") { engine.skip() }
                        .buttonStyle(PillButtonStyle(fill: .white, prominent: false))
                    Button("Reset") { engine.reset() }
                        .buttonStyle(PillButtonStyle(fill: .white, prominent: false))
                }
            }
            .padding(.horizontal, 22)
            TodayRow(count: engine.todayFocusCount(),
                     minutes: engine.todayFocusMinutes(),
                     target: engine.sessionsTotal)
                .padding(.horizontal, 22)
            FocusHeatmapView(grid: FocusHeatmap.cells(history: engine.history, today: Date(), calendar: .current),
                             pulsing: engine.isRunning && engine.phase == .focus)
                .equatable()
                .padding(.horizontal, FocusHeatmapView.sidePadding)
                .padding(.top, 4)
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// GitHub's contribution graph, dark theme: 52 weeks × 7 days, Sunday on top, today outlined
/// (and pulsing while a focus session runs).
struct FocusHeatmapView: View, Equatable {
    var grid: FocusHeatmap.Grid
    var pulsing: Bool

    static let square: CGFloat = 7
    static let gap: CGFloat = 1.5
    static let pitch: CGFloat = square + gap
    static let rowLabelWidth: CGFloat = 26
    static let sidePadding: CGFloat = 6
    static let gridWidth = CGFloat(FocusHeatmap.weeks) * pitch - gap
    /// Width the Focus tab needs: padding + row labels + grid + padding.
    static let panelWidth: CGFloat = 480

    static let grey = Color(hex: 0x8B949E)
    static let levels: [Color] = [Color(hex: 0x161B22), Color(hex: 0x0E4429), Color(hex: 0x006D32),
                                  Color(hex: 0x26A641), Color(hex: 0x39D353)]
    static let emptyBorder = Color.white.opacity(Double(0x0D) / 255)

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    static func help(_ cell: FocusHeatmap.Cell) -> String {
        let minutes = Int(cell.minutes.rounded())
        let sessions = "\(cell.sessions) session\(cell.sessions == 1 ? "" : "s")"
        return "\(dayFormat.string(from: cell.date)) · \(minutes) min · \(sessions)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            monthRow
            HStack(alignment: .top, spacing: 0) {
                rowLabels
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(0..<FocusHeatmap.weeks, id: \.self) { column in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<FocusHeatmap.daysPerWeek, id: \.self) { row in
                                cell(grid.cell(column: column, row: row))
                            }
                        }
                    }
                }
            }
            footer.padding(.top, 3)
        }
    }

    private var monthRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(grid.monthLabels, id: \.column) { label in
                Text(label.text)
                    .font(.system(size: 8))
                    .foregroundColor(Self.grey)
                    .fixedSize()
                    .offset(x: Self.rowLabelWidth + CGFloat(label.column) * Self.pitch)
            }
        }
        .frame(width: Self.rowLabelWidth + Self.gridWidth, height: 10, alignment: .topLeading)
    }

    private var rowLabels: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(0..<FocusHeatmap.daysPerWeek, id: \.self) { row in
                Text(row == 1 ? "Mon" : row == 3 ? "Wed" : row == 5 ? "Fri" : "")
                    .font(.system(size: 8))
                    .foregroundColor(Self.grey)
                    .fixedSize()
                    .frame(width: Self.rowLabelWidth, height: Self.square, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func cell(_ c: FocusHeatmap.Cell) -> some View {
        if c.isFuture {
            Color.clear.frame(width: Self.square, height: Self.square)  // not drawn, like GitHub
        } else if c.isToday && pulsing {
            PhaseAnimator([0.6, 1.0]) { opacity in
                square(c).opacity(opacity)
            } animation: { _ in .easeInOut(duration: 1.2) }
            .help(Self.help(c))
        } else {
            square(c).help(Self.help(c))
        }
    }

    private func square(_ c: FocusHeatmap.Cell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 1.5)
        return shape
            .fill(Self.levels[c.level])
            .overlay(shape.strokeBorder(Self.emptyBorder, lineWidth: c.level == 0 ? 1 : 0))
            .overlay(shape.strokeBorder(Color.white, lineWidth: c.isToday ? 1 : 0))
            .frame(width: Self.square, height: Self.square)
    }

    private var footer: some View {
        let minutes = Int(grid.totalMinutes.rounded())
        let sessions = grid.totalSessions
        return HStack(spacing: 3) {
            Text("\(minutes / 60) h \(minutes % 60) min · \(sessions) session\(sessions == 1 ? "" : "s") in the last year")
                .font(.system(size: 9))
                .foregroundColor(Self.grey)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("Less").font(.system(size: 8)).foregroundColor(Self.grey)
            ForEach(0..<Self.levels.count, id: \.self) { level in
                let shape = RoundedRectangle(cornerRadius: 1.5)
                shape.fill(Self.levels[level])
                    .overlay(shape.strokeBorder(Self.emptyBorder, lineWidth: level == 0 ? 1 : 0))
                    .frame(width: Self.square, height: Self.square)
            }
            Text("More").font(.system(size: 8)).foregroundColor(Self.grey)
        }
        .padding(.leading, Self.rowLabelWidth)
    }
}

extension Color {
    /// 0xRRGGBB, opaque sRGB.
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
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
