import Combine
import IOKit.ps
import SwiftUI

/// One reading of the internal battery.
struct BatterySnapshot: Equatable, Sendable {
    var percent: Int
    var onAC: Bool
    var charging: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is still estimating.
    var minutesRemaining: Int?
}

/// Pure transition rules, so the transients are testable without IOKit.
struct BatteryTransitions: Sendable {
    var lowThresholds: [Int] = [20, 10]
    /// Thresholds already announced during the current discharge.
    private(set) var announced: Set<Int> = []
    private(set) var last: BatterySnapshot?

    mutating func update(_ s: BatterySnapshot) -> [Transient] {
        defer { last = s }
        var out: [Transient] = []
        if s.onAC { announced.removeAll() }
        if let last, last.onAC != s.onAC {
            out.append(s.onAC
                ? Transient("Charging · \(s.percent)%", systemImage: "bolt.fill", tint: .green, fill: Double(s.percent) / 100)
                : Transient("On battery · \(s.percent)%", systemImage: "battery.50", tint: .orange, fill: Double(s.percent) / 100))
        }
        if !s.onAC {
            // Lowest crossed threshold not yet announced this discharge.
            let crossed = lowThresholds.filter { s.percent <= $0 && !announced.contains($0) }
            if !crossed.isEmpty {
                announced.formUnion(crossed)
                out.append(Transient("Low battery · \(s.percent)%", systemImage: "battery.25",
                                     tint: .red, fill: Double(s.percent) / 100))
            }
        }
        return out
    }
}

/// Module 6: IOKit power sources. Header strip shows percent + time remaining; transients on
/// power connect/disconnect and at the low thresholds. No permission needed.
@MainActor
final class BatteryModule: ObservableObject, NotchModule {
    struct Settings: Codable, Equatable, Sendable {
        var transientsEnabled = true
        var lowFirst = 20
        var lowSecond = 10
    }

    let id = "battery"
    let title = "Battery"
    let systemImage = "battery.75"
    let panelHeight: CGFloat = 0
    var showsTab: Bool { false }
    var headerPlacement: HeaderPlacement { .left }

    @Published var settings: Settings {
        didSet {
            AppDefaults.encode(settings, to: defaults, key: "battery.settings")
            transitions.lowThresholds = [settings.lowFirst, settings.lowSecond]
        }
    }
    @Published private(set) var snapshot: BatterySnapshot?

    private let defaults: UserDefaults
    private let notify: TransientSink
    private var transitions = BatteryTransitions()
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?

    init(defaults: UserDefaults, notify: @escaping TransientSink) {
        self.defaults = defaults
        self.notify = notify
        settings = AppDefaults.decode(Settings.self, from: defaults, key: "battery.settings") ?? Settings()
        transitions.lowThresholds = [settings.lowFirst, settings.lowSecond]
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Called on the main run loop whenever a power source changes.
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let module = Unmanaged<BatteryModule>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { module.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        // Time remaining drifts without a power event; re-read every minute.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let s = Self.read()
        if s != snapshot { snapshot = s }
        guard let s else { return }
        let out = transitions.update(s)
        if settings.transientsEnabled { out.forEach(notify) }
    }

    /// The internal battery, or nil on a Mac without one.
    static func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let raw = (charging ? desc[kIOPSTimeToFullChargeKey] : desc[kIOPSTimeToEmptyKey]) as? Int
            let minutes = (raw ?? -1) > 0 ? raw : nil
            return BatterySnapshot(percent: percent, onAC: onAC, charging: charging, minutesRemaining: minutes)
        }
        return nil
    }

    var headerView: AnyView? {
        guard snapshot != nil else { return nil }
        return AnyView(BatteryHeaderView(module: self))
    }
    var expandedView: AnyView { AnyView(EmptyView()) }
    var settingsView: AnyView { AnyView(BatterySettingsView(module: self)) }
}

struct BatteryHeaderView: View {
    @ObservedObject var module: BatteryModule

    private func symbol(_ s: BatterySnapshot) -> String {
        if s.charging { return "battery.100.bolt" }
        switch s.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        if let s = module.snapshot {
            let color: Color = s.charging ? Palette.green : (s.percent <= module.settings.lowSecond ? Palette.red : .white)
            HStack(spacing: 4) {
                Image(systemName: symbol(s))
                    .font(.system(size: 12))
                    .foregroundColor(color)
                Text(Self.text(s))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(s.charging ? "Charging" : (s.onAC ? "On power adapter" : "On battery"))
        }
    }

    /// "64% · 3:12" (h:mm remaining) or "64%" while estimating / full on AC.
    static func text(_ s: BatterySnapshot) -> String {
        guard let m = s.minutesRemaining, !(s.onAC && !s.charging) else { return "\(s.percent)%" }
        return "\(s.percent)% · \(m / 60):" + String(format: "%02d", m % 60)
    }
}

struct BatterySettingsView: View {
    @ObservedObject var module: BatteryModule

    var body: some View {
        Toggle("Show power and low-battery alerts in the notch", isOn: $module.settings.transientsEnabled)
        Stepper("First low alert: \(module.settings.lowFirst)%", value: $module.settings.lowFirst, in: 5...50)
        Stepper("Second low alert: \(module.settings.lowSecond)%", value: $module.settings.lowSecond, in: 1...30)
        Text("Percent and time remaining are shown left of the notch when the panel is open.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
