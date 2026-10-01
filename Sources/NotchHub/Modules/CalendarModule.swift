import AppKit
import Combine
import EventKit
import SwiftUI

/// A today event, copied out of EventKit (EKEvent is not Sendable).
struct DayEvent: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: [Double]
    var joinURL: URL?
}

enum MeetingLink {
    /// Zoom, Google Meet and Microsoft Teams join links.
    static let pattern = #"https?://(?:[a-z0-9-]+\.)*zoom\.us/(?:j|my|s|w)/[^\s<>"']+|https?://meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}[^\s<>"']*|https?://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+|https?://teams\.live\.com/meet/[^\s<>"']+"#

    static func find(in fields: [String?]) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for field in fields.compactMap({ $0 }) {
            let range = NSRange(field.startIndex..., in: field)
            if let match = regex.firstMatch(in: field, range: range), let r = Range(match.range, in: field) {
                let raw = String(field[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>"))
                if let url = URL(string: raw) { return url }
            }
        }
        return nil
    }
}

enum CalendarText {
    /// "Standup in 12m", "Standup in 1h 5m", "Standup now"; nil when nothing is left today.
    static func headline(_ events: [DayEvent], now: Date) -> String? {
        let timed = events.filter { !$0.isAllDay && $0.end > now }.sorted { $0.start < $1.start }
        guard let next = timed.first else { return nil }
        let title = next.title.isEmpty ? "Event" : next.title
        if next.start <= now { return "\(title) now" }
        let minutes = Int((next.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "\(title) in \(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(title) in \(h)h" : "\(title) in \(h)h \(m)m"
    }
}

/// Module 7: EventKit, read-only. Access is requested the first time the Calendar tab is opened.
@MainActor
final class CalendarModule: ObservableObject, NotchModule {
    struct Settings: Codable, Equatable, Sendable {
        /// Calendars switched off (new calendars are included by default).
        var excludedCalendarIDs: [String] = []
    }

    enum Access: Equatable { case notDetermined, granted, denied }

    struct CalendarInfo: Identifiable, Equatable {
        var id: String
        var title: String
        var source: String
    }

    let id = "calendar"
    let title = "Calendar"
    let systemImage = "calendar"
    let panelHeight: CGFloat = 200
    var headerPlacement: HeaderPlacement { .tabRow }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published var settings: Settings {
        didSet {
            AppDefaults.encode(settings, to: defaults, key: "calendar.settings")
            refresh()
        }
    }

    private let defaults: UserDefaults
    private var store: EKEventStore?
    private var timers: [Timer] = []
    private var changeObserver: NSObjectProtocol?
    private var running = false
    private var requesting = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = AppDefaults.decode(Settings.self, from: defaults, key: "calendar.settings") ?? Settings()
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied // denied, restricted, write-only
        }
    }

    func start() {
        running = true
        access = Self.currentAccess()
        if access == .granted { begin() }
    }

    func stop() {
        running = false
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func visibilityChanged(expanded: Bool, selected: Bool) {
        // First use of the module = first time its tab is shown.
        if selected, access == .notDetermined { requestAccess() }
    }

    func requestAccess() {
        guard !requesting else { return }
        requesting = true
        let store = self.store ?? EKEventStore()
        self.store = store
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.requesting = false
                self.access = granted ? .granted : Self.currentAccess()
                if self.access == .granted, self.running { self.begin() }
            }
        }
    }

    private func begin() {
        if store == nil { store = EKEventStore() }
        guard timers.isEmpty else { refresh(); return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let every5 = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Keeps "in 12m" current between refreshes.
        let minute = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        for t in [every5, minute] {
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
        }
        timers = [every5, minute]
        refresh()
    }

    func refresh() {
        guard access == .granted, let store else { return }
        let all = store.calendars(for: .event)
        calendars = all.map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        let included = all.filter { !settings.excludedCalendarIDs.contains($0.calendarIdentifier) }
        guard !included.isEmpty else { events = []; return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: included)
        events = store.events(matching: predicate)
            .map { e in
                let c = e.calendar.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
                return DayEvent(id: e.eventIdentifier ?? UUID().uuidString,
                                title: e.title ?? "",
                                start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                                color: [Double(c?.redComponent ?? 0.5), Double(c?.greenComponent ?? 0.5),
                                        Double(c?.blueComponent ?? 0.5)],
                                joinURL: MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes]))
            }
            .sorted { $0.start < $1.start }
    }

    func isIncluded(_ id: String) -> Bool { !settings.excludedCalendarIDs.contains(id) }

    func setIncluded(_ id: String, _ on: Bool) {
        settings.excludedCalendarIDs.removeAll { $0 == id }
        if !on { settings.excludedCalendarIDs.append(id) }
    }

    var remainingToday: [DayEvent] {
        let now = Date()
        return events.filter { $0.end > now }
    }

    var headerView: AnyView? {
        guard access == .granted, CalendarText.headline(events, now: Date()) != nil else { return nil }
        return AnyView(CalendarHeaderView(module: self))
    }
    var expandedView: AnyView { AnyView(CalendarView(module: self)) }
    var settingsView: AnyView { AnyView(CalendarSettingsView(module: self)) }
}

struct CalendarHeaderView: View {
    @ObservedObject var module: CalendarModule

    var body: some View {
        if let text = CalendarText.headline(module.events, now: Date()) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(.white.opacity(0.8))
            .frame(maxWidth: 160, alignment: .trailing)
        }
    }
}

struct CalendarView: View {
    @ObservedObject var module: CalendarModule

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        switch module.access {
        case .notDetermined:
            PermissionNotice(systemImage: "calendar", message: "NotchHub shows today's events read-only.",
                             buttonTitle: "Allow Calendar access") { module.requestAccess() }
        case .denied:
            PermissionNotice(systemImage: "calendar.badge.exclamationmark",
                             message: "Calendar access is off. Turn on NotchHub under Privacy & Security › Calendars.",
                             settingsURL: SystemSettingsURL.calendars)
        case .granted:
            let events = module.remainingToday
            if events.isEmpty {
                Text("Nothing left today.")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(events) { event in row(event) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ e: DayEvent) -> some View {
        let now = Date()
        let live = !e.isAllDay && e.start <= now && e.end > now
        return HStack(spacing: 8) {
            Capsule()
                .fill(Color(red: e.color[0], green: e.color[1], blue: e.color[2]))
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title.isEmpty ? "Untitled" : e.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(e.isAllDay ? "All day" : "\(Self.time.string(from: e.start)) – \(Self.time.string(from: e.end))" + (live ? " · now" : ""))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(live ? Palette.green : Palette.dim)
            }
            Spacer(minLength: 4)
            if let url = e.joinURL {
                Button("Join") { NSWorkspace.shared.open(url) }
                    .buttonStyle(PillButtonStyle(fill: Palette.green, prominent: true))
                    .help(url.absoluteString)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(live ? 0.1 : 0.04)))
    }
}

struct CalendarSettingsView: View {
    @ObservedObject var module: CalendarModule

    var body: some View {
        switch module.access {
        case .granted:
            if module.calendars.isEmpty {
                Text("No calendars found.").foregroundColor(.secondary)
            }
            ForEach(module.calendars) { c in
                Toggle("\(c.title) (\(c.source))", isOn: Binding(get: { module.isIncluded(c.id) },
                                                                 set: { module.setIncluded(c.id, $0) }))
            }
        case .notDetermined:
            HStack {
                Text("Access is requested when you first open the Calendar tab.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Allow now") { module.requestAccess() }
            }
        case .denied:
            HStack {
                Text("Calendar access is off.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Open System Settings") {
                    if let url = URL(string: SystemSettingsURL.calendars) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
