import AppKit

/// Lets a non-human drive the real app for verification (docs/BRIEF-v3.md §1).
/// Only exists when `debugDriver` is true in the app's defaults at launch; otherwise it is never
/// created, so no timer runs and no file is read. Polls ~/Library/Logs/notchhub-cmd.txt every
/// 0.5 s, runs each line, truncates the file, and logs `cmd <line> ok|err <reason>` to NotchHub.log.
@MainActor
final class DebugDriver {
    static let flagKey = "debugDriver"

    struct Targets {
        var hub: HubStore
        var window: NotchWindowController
        var engine: PomodoroEngine
        var caffeine: CaffeineModule
        var clipboard: ClipboardModule
        var notes: NotesModule
    }

    private let targets: Targets
    private var timer: Timer?
    /// Lines waiting behind a `wait`.
    private var pending: [String] = []
    private var resumeAt: Date?

    private static let logs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)
    static let commandFile = logs.appendingPathComponent("notchhub-cmd.txt")

    /// nil unless the flag is on.
    static func startIfEnabled(defaults: UserDefaults, targets: Targets) -> DebugDriver? {
        guard defaults.bool(forKey: flagKey) else { return nil }
        let driver = DebugDriver(targets: targets)
        driver.start()
        return driver
    }

    private init(targets: Targets) { self.targets = targets }

    private func start() {
        DebugLog.write("debug driver on, watching \(Self.commandFile.path)")
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        if let data = try? Data(contentsOf: Self.commandFile), !data.isEmpty {
            try? Data().write(to: Self.commandFile)
            let text = String(decoding: data, as: UTF8.self)
            pending += text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let resumeAt, Date() < resumeAt { return }
        resumeAt = nil
        while !pending.isEmpty {
            let line = pending.removeFirst()
            let result = run(line)
            DebugLog.write("cmd \(line) \(result)")
            if resumeAt != nil { return }  // `wait`: the rest runs on a later poll
        }
    }

    /// "ok", "ok <detail>" or "err <reason>".
    private func run(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts[0].lowercased()
        let arg = parts.count > 1 ? parts[1] : ""
        let t = targets
        switch verb {
        case "expand":
            t.window.expand(byHover: false)
        case "collapse":
            t.window.collapse()
        case "toggle":
            t.window.toggleExpanded()
        case "tab":
            guard let module = t.hub.visibleTabs.first(where: { $0.id.lowercased() == arg.lowercased() }) else {
                return "err no visible tab '\(arg)' (have: \(t.hub.visibleTabs.map(\.id).joined(separator: ",")))"
            }
            t.hub.select(module.id)
            t.window.expand(byHover: false)
        case "snapshot":
            let name = arg.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !name.isEmpty else { return "err snapshot needs a name" }
            let url = Self.logs.appendingPathComponent("notchhub-\(name).png")
            guard let frames = t.window.snapshot(to: url) else { return "err could not render" }
            DebugLog.write("snapshot \(name) host=\(frames.host) window=\(frames.window)")
            return "ok \(url.path)"
        case "focus":
            switch arg.lowercased() {
            case "start": t.engine.start()
            case "pause": t.engine.pause()
            case "skip": t.engine.skip()
            case "reset": t.engine.reset()
            default: return "err focus start|pause|skip|reset"
            }
            return "ok running=\(t.engine.isRunning) phase=\(t.engine.phase.rawValue) left=\(t.engine.timeString)"
        case "caffeine":
            switch arg.lowercased() {
            case "on": if !t.caffeine.isOn { t.caffeine.activate(minutes: t.caffeine.settings.defaultMinutes) }
            case "off": t.caffeine.deactivate()
            default: return "err caffeine on|off"
            }
            return "ok isOn=\(t.caffeine.isOn)"
        case "transient":
            guard !arg.isEmpty else { return "err transient needs text" }
            t.hub.show(Self.transient(arg))
        case "clip":
            let sub = arg.split(separator: " ")
            guard sub.count == 2, sub[0] == "select", let index = Int(sub[1]) else {
                return "err clip select <index> (0 = top row)"
            }
            let rows = t.clipboard.history.filtered(t.clipboard.query)
            guard rows.indices.contains(index) else { return "err index \(index) of \(rows.count) rows" }
            let item = rows[index]
            t.clipboard.copyBack(item)  // the same call a row click makes
            return "ok copied '\(item.preview)'"
        case "notes":
            guard arg.lowercased().hasPrefix("set") else { return "err notes set <text>" }
            t.notes.text = String(arg.dropFirst(3)).trimmingCharacters(in: .whitespaces)  // = the editor binding
            return "ok words=\(t.notes.wordCount)"
        case "wait":
            guard let seconds = Double(arg), seconds > 0 else { return "err wait <seconds>" }
            resumeAt = Date().addingTimeInterval(seconds)
        default:
            return "err unknown command"
        }
        return "ok"
    }

    /// "Charging · 64%" renders exactly like the battery module's transient; anything else is plain.
    private static func transient(_ text: String) -> Transient {
        let percent = text.split(separator: "·").last
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }
        if text.hasPrefix("Charging"), let percent {
            return Transient(text, systemImage: "bolt.fill", tint: .green, fill: percent / 100)
        }
        if text.hasPrefix("On battery"), let percent {
            return Transient(text, systemImage: "battery.50", tint: .orange, fill: percent / 100)
        }
        return Transient(text, systemImage: "info.circle.fill", tint: .white)
    }
}
