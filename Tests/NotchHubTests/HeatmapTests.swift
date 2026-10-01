#if canImport(Testing)
import Foundation
import Testing
@testable import NotchHub

@Suite struct FocusHeatmapTests {
    /// Monday-first locale on purpose: the grid must still put Sunday on row 0.
    static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        cal.firstWeekday = 2
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    static func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar().date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    static func focus(_ end: Date, _ minutes: Double) -> SessionRecord {
        SessionRecord(startedAt: end.addingTimeInterval(-minutes * 60), endedAt: end, phase: .focus, minutes: minutes)
    }

    @Test func levelThresholds() {
        #expect(FocusHeatmap.level(minutes: 0) == 0)
        #expect(FocusHeatmap.level(minutes: 1) == 1)
        #expect(FocusHeatmap.level(minutes: 24) == 1)
        #expect(FocusHeatmap.level(minutes: 25) == 2)
        #expect(FocusHeatmap.level(minutes: 49) == 2)
        #expect(FocusHeatmap.level(minutes: 50) == 3)
        #expect(FocusHeatmap.level(minutes: 99) == 3)
        #expect(FocusHeatmap.level(minutes: 100) == 4)
        #expect(FocusHeatmap.level(minutes: 600) == 4)
    }

    @Test func fiftyTwoWeekWindowSundayFirst() {
        let cal = Self.calendar()
        let today = Self.day(2026, 10, 1)            // a Thursday
        let grid = FocusHeatmap.cells(history: [], today: today, calendar: cal)
        #expect(grid.cells.count == 52 * 7)
        for column in 0..<52 {
            for row in 0..<7 {
                let c = grid.cell(column: column, row: row)
                #expect(cal.component(.weekday, from: c.date) == row + 1)   // row 0 = Sunday
            }
        }
        // Rightmost column = the current week (Sun Sep 27 … Sat Oct 3); leftmost = 51 weeks earlier.
        #expect(grid.cell(column: 51, row: 0).date == cal.startOfDay(for: Self.day(2026, 9, 27)))
        #expect(grid.cell(column: 0, row: 0).date == cal.startOfDay(for: Self.day(2025, 10, 5)))
        // Consecutive days, no gaps, even across DST in other zones.
        for i in 1..<grid.cells.count {
            #expect(cal.dateComponents([.day], from: grid.cells[i - 1].date, to: grid.cells[i].date).day == 1)
        }
    }

    @Test func todayIndexAndFutureMasking() {
        let cal = Self.calendar()
        let grid = FocusHeatmap.cells(history: [], today: Self.day(2026, 10, 1, hour: 23), calendar: cal)
        let todays = grid.cells.enumerated().filter { $0.element.isToday }
        #expect(todays.count == 1)
        #expect(todays.first?.offset == 51 * 7 + 4)          // last column, Thursday row
        let future = grid.cells.enumerated().filter { $0.element.isFuture }.map(\.offset)
        #expect(future == [51 * 7 + 5, 51 * 7 + 6])         // Fri + Sat of this week
        // On a Saturday nothing is in the future.
        let saturday = FocusHeatmap.cells(history: [], today: Self.day(2026, 10, 3), calendar: cal)
        #expect(saturday.cells.allSatisfy { !$0.isFuture })
        #expect(saturday.cells.last?.isToday == true)
    }

    @Test func bucketsFocusOnlyByLocalDay() {
        let cal = Self.calendar()
        let today = Self.day(2026, 10, 1)
        let history = [
            Self.focus(Self.day(2026, 10, 1, hour: 9), 25),
            Self.focus(Self.day(2026, 10, 1, hour: 11), 25),
            SessionRecord(startedAt: today, endedAt: Self.day(2026, 10, 1, hour: 10), phase: .shortBreak, minutes: 5),
            Self.focus(Self.day(2026, 9, 30, hour: 23), 100),
            Self.focus(Self.day(2024, 1, 1), 25),             // outside the window
        ]
        let grid = FocusHeatmap.cells(history: history, today: today, calendar: cal)
        let t = grid.cell(column: 51, row: 4)
        #expect(t.minutes == 50 && t.sessions == 2 && t.level == 3)
        let y = grid.cell(column: 51, row: 3)
        #expect(y.minutes == 100 && y.level == 4)
        #expect(grid.totalMinutes == 150)
        #expect(grid.totalSessions == 3)
    }

    @Test func monthLabelsOnTheColumnContainingTheFirst() {
        let cal = Self.calendar()
        let grid = FocusHeatmap.cells(history: [], today: Self.day(2026, 10, 1), calendar: cal)
        // Columns start Sun 2025-10-05. Oct at 0; Nov 1 (Sat) sits in column 3 (Oct 26 – Nov 1);
        // the current week (Sep 27 – Oct 3) contains Oct 1, so "Oct" is labelled again at column 51.
        #expect(grid.monthLabels.map(\.text) ==
                ["Oct", "Nov", "Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct"])
        #expect(grid.monthLabels.first?.column == 0)
        #expect(grid.monthLabels.dropFirst().first?.column == 3)
        #expect(grid.monthLabels.last?.column == 51)
        for label in grid.monthLabels {
            // The column's last day (Saturday) is in the labelled month.
            #expect(cal.component(.month, from: grid.cell(column: label.column, row: 6).date) == label.month)
        }
    }

    @Test func monthLabelOverlapDropsTheEarlierPartialMonth() {
        let cal = Self.calendar()
        // Today Sun 2027-01-17: column 0 = Jan 25–31 2026 (Jan), column 1 = Feb 1–7 (Feb) → 1 column
        // apart, so the partial "Jan" at the left edge is dropped and "Feb" at column 1 leads.
        let grid = FocusHeatmap.cells(history: [], today: Self.day(2027, 1, 17), calendar: cal)
        #expect(grid.monthLabels.first?.text == "Feb")
        #expect(grid.monthLabels.first?.column == 1)
        #expect(grid.monthLabels.last?.text == "Jan")          // the new January at the right edge
        let columns = grid.monthLabels.map(\.column)
        for (a, b) in zip(columns, columns.dropFirst()) { #expect(b - a >= FocusHeatmap.minLabelGap) }
    }
}
#endif
