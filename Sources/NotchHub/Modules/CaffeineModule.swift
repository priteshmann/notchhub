import Combine
import IOKit.pwr_mgt
import SwiftUI

/// Module 8: keep the display awake with an IOPM assertion, optionally for a fixed time.
@MainActor
final class CaffeineModule: ObservableObject, NotchModule {
    struct Settings: Codable, Equatable, Sendable {
        /// Default duration for a one-click toggle; 0 = until turned off.
        var defaultMinutes: Int = 0
    }

    static let durations: [(label: String, minutes: Int)] = [
        ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("Until turned off", 0),
    ]

    let id = "caffeine"
    let title = "Caffeine"
    let systemImage = "cup.and.saucer.fill"
    let panelHeight: CGFloat = 0
    var showsTab: Bool { false }
    var headerPlacement: HeaderPlacement { .right }

    @Published var settings: Settings {
        didSet { AppDefaults.encode(settings, to: defaults, key: "caffeine.settings") }
    }
    @Published private(set) var isOn = false
    /// Wall-clock end (nil = until off).
    @Published private(set) var endDate: Date?

    private let defaults: UserDefaults
    private let notify: TransientSink
    private var assertionID = IOPMAssertionID(0)
    private var timer: Timer?

    init(defaults: UserDefaults, notify: @escaping TransientSink) {
        self.defaults = defaults
        self.notify = notify
        settings = AppDefaults.decode(Settings.self, from: defaults, key: "caffeine.settings") ?? Settings()
    }

    func start() {}
    func stop() { deactivate(announce: false) }

    func toggle() {
        isOn ? deactivate() : activate(minutes: settings.defaultMinutes)
    }

    /// minutes 0 = until turned off.
    func activate(minutes: Int) {
        if assertionID == 0 {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NotchHub Caffeine" as CFString,
                &newID)
            guard result == kIOReturnSuccess else {
                notify(Transient("Caffeine failed", systemImage: "exclamationmark.triangle", tint: .red))
                return
            }
            assertionID = newID
        }
        isOn = true
        endDate = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        startTimer()
        notify(Transient(minutes > 0 ? "Awake · \(Self.label(minutes: minutes))" : "Awake until off",
                         systemImage: "cup.and.saucer.fill", tint: .orange))
    }

    func deactivate(announce: Bool = true) {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        timer?.invalidate()
        timer = nil
        let wasOn = isOn
        isOn = false
        endDate = nil
        if announce, wasOn {
            notify(Transient("Caffeine off", systemImage: "cup.and.saucer", tint: .white))
        }
    }

    var remainingText: String {
        guard isOn else { return "" }
        guard let endDate else { return "∞" }
        let minutes = max(0, Int((endDate.timeIntervalSinceNow / 60).rounded(.up)))
        return Self.label(minutes: minutes, short: true)
    }

    static func label(minutes: Int, short: Bool = false) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return short ? "\(minutes)m" : "\(minutes) min"
    }

    /// Checks the wall-clock end every 15 s (never counts ticks).
    private func startTimer() {
        timer?.invalidate()
        guard endDate != nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if let endDate, Date() >= endDate {
            deactivate()
        } else {
            objectWillChange.send()
        }
    }

    var headerView: AnyView? { AnyView(CaffeineHeaderView(module: self)) }
    var expandedView: AnyView { AnyView(EmptyView()) }
    var settingsView: AnyView { AnyView(CaffeineSettingsView(module: self)) }
}

struct CaffeineHeaderView: View {
    @ObservedObject var module: CaffeineModule

    var body: some View {
        Button {
            module.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: module.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 12, weight: .medium))
                if module.isOn {
                    Text(module.remainingText)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundColor(module.isOn ? Palette.orange : .white.opacity(0.7))
            .frame(minWidth: 22, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(module.isOn ? "Caffeine on: click to let the display sleep" : "Caffeine: keep the display awake")
    }
}

struct CaffeineSettingsView: View {
    @ObservedObject var module: CaffeineModule

    var body: some View {
        Picker("Default duration", selection: $module.settings.defaultMinutes) {
            ForEach(CaffeineModule.durations, id: \.minutes) { d in
                Text(d.label).tag(d.minutes)
            }
        }
        Text("The cup in the panel header toggles it; the menu bar item offers every duration.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
