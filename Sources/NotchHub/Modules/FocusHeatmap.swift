import Foundation

/// GitHub-style contribution grid of completed focus sessions over a trailing year.
/// Pure: no UI, no clock of its own, so it is testable with an injected `today` and calendar.
enum FocusHeatmap {
    static let weeks = 52
    static let daysPerWeek = 7
    /// Two month labels closer than this many columns would overlap (8 pt text, 8.5 pt pitch).
    static let minLabelGap = 3

    struct Cell: Equatable, Sendable {
        /// Start of the local day.
        var date: Date
        var minutes: Double
        var sessions: Int
        /// 0...4, GitHub's five colours.
        var level: Int
        var isToday: Bool
        var isFuture: Bool
    }

    struct MonthLabel: Equatable, Sendable {
        var column: Int
        /// Short month name, e.g. "Oct".
        var text: String
        var month: Int
    }

    struct Grid: Equatable, Sendable {
        /// `weeks` × 7 cells, column-major: `cells[column * 7 + row]`, row 0 = Sunday.
        var cells: [Cell]
        var monthLabels: [MonthLabel]

        func cell(column: Int, row: Int) -> Cell { cells[column * FocusHeatmap.daysPerWeek + row] }

        var totalMinutes: Double { cells.filter { !$0.isFuture }.reduce(0) { $0 + $1.minutes } }
        var totalSessions: Int { cells.filter { !$0.isFuture }.reduce(0) { $0 + $1.sessions } }
    }

    /// GitHub dark thresholds: 0 → 0, 1–24 → 1, 25–49 → 2, 50–99 → 3, ≥100 → 4 (minutes).
    static func level(minutes: Double) -> Int {
        switch minutes {
        case ..<0.5: return 0
        case ..<25: return 1
        case ..<50: return 2
        case ..<100: return 3
        default: return 4
        }
    }

    /// Row of a date in GitHub's grid: Sunday = 0 … Saturday = 6, whatever the locale's first weekday.
    static func row(of date: Date, calendar: Calendar) -> Int {
        calendar.component(.weekday, from: date) - 1
    }

    static func cells(history: [SessionRecord], today: Date, calendar: Calendar) -> Grid {
        let todayStart = calendar.startOfDay(for: today)
        // Sunday of the current week = the rightmost column; the grid starts 51 weeks earlier.
        let currentSunday = calendar.date(byAdding: .day, value: -row(of: todayStart, calendar: calendar), to: todayStart)!
        let firstDay = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: currentSunday)!

        // Bucket completed focus sessions by local day of their end.
        var minutesByDay: [Date: Double] = [:]
        var sessionsByDay: [Date: Int] = [:]
        for record in history where record.phase == .focus {
            let day = calendar.startOfDay(for: record.endedAt)
            minutesByDay[day, default: 0] += record.minutes
            sessionsByDay[day, default: 0] += 1
        }

        var cells: [Cell] = []
        cells.reserveCapacity(weeks * daysPerWeek)
        for column in 0..<weeks {
            for row in 0..<daysPerWeek {
                // Day arithmetic (not 86 400 s steps), so DST changes never shift a row.
                let date = calendar.date(byAdding: .day, value: column * 7 + row, to: firstDay)!
                let minutes = minutesByDay[date] ?? 0
                cells.append(Cell(date: date, minutes: minutes, sessions: sessionsByDay[date] ?? 0,
                                  level: level(minutes: minutes),
                                  isToday: date == todayStart, isFuture: date > todayStart))
            }
        }
        return Grid(cells: cells, monthLabels: monthLabels(cells: cells, calendar: calendar))
    }

    /// A label above the first column whose first day (Sunday) falls in a new month. When two
    /// labels would overlap, the earlier one goes (it can only be the partial month at the left edge).
    static func monthLabels(cells: [Cell], calendar: Calendar) -> [MonthLabel] {
        let symbols = calendar.shortMonthSymbols
        var raw: [MonthLabel] = []
        var lastMonth: Int?
        for column in 0..<(cells.count / daysPerWeek) {
            let month = calendar.component(.month, from: cells[column * daysPerWeek].date)
            if month != lastMonth {
                raw.append(MonthLabel(column: column, text: symbols[month - 1], month: month))
                lastMonth = month
            }
        }
        var kept: [MonthLabel] = []
        for label in raw {
            if let previous = kept.last, label.column - previous.column < minLabelGap {
                kept.removeLast()
            }
            kept.append(label)
        }
        return kept
    }
}
