import AppKit
import Combine

/// Menu bar fallback: "🍅 24:59" while a session runs. The same menu opens on a right-click of
/// the collapsed notch.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine: PomodoroEngine
    private let caffeine: CaffeineModule
    private let hub: HubStore
    private let openPanel: () -> Void
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(engine: PomodoroEngine, caffeine: CaffeineModule, hub: HubStore,
         openPanel: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.engine = engine
        self.caffeine = caffeine
        self.hub = hub
        self.openPanel = openPanel
        self.openSettings = openSettings
        super.init()
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        // objectWillChange fires before the change; hop to the next main-loop turn to read new values.
        Publishers.Merge(engine.objectWillChange, caffeine.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitle() }
            }
            .store(in: &cancellables)
    }

    private func refreshTitle() {
        let cup = caffeine.isOn ? " ☕" : ""
        let title: String
        if engine.isRunning {
            title = "🍅 \(engine.timeString)\(cup)"
        } else if engine.isActive {
            title = "⏸ \(engine.timeString)\(cup)"
        } else {
            title = "🍅\(cup)"
        }
        if item.button?.title != title { item.button?.title = title }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    /// A fresh copy of the menu (for the notch's right-click).
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(makeItem(engine.isRunning ? "Pause focus" : "Start focus", #selector(toggle)))
        menu.addItem(makeItem("Skip", #selector(skip)))
        menu.addItem(makeItem("Reset", #selector(reset)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Open panel", #selector(open)))

        let caffeineItem = NSMenuItem(title: "Caffeine", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let off = makeItem("Off", #selector(caffeineOff))
        off.state = caffeine.isOn ? .off : .on
        sub.addItem(off)
        for d in CaffeineModule.durations {
            let mi = makeItem(d.label, #selector(caffeineOn(_:)))
            mi.tag = d.minutes
            sub.addItem(mi)
        }
        caffeineItem.submenu = sub
        caffeineItem.state = caffeine.isOn ? .on : .off
        caffeineItem.isEnabled = hub.isEnabled(caffeine.id)
        menu.addItem(caffeineItem)

        let login = makeItem("Launch at login", #selector(toggleLogin))
        login.state = engine.settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(makeItem("Settings…", #selector(settings), key: ","))
        menu.addItem(.separator())
        for hint in ["⌃⌥P starts / pauses focus", "⌃⌥N opens / closes the notch"] {
            let mi = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        menu.addItem(makeItem("Quit NotchHub", #selector(quit), key: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func toggle() { engine.toggle() }
    @objc private func skip() { engine.skip() }
    @objc private func reset() { engine.reset() }
    @objc private func open() { openPanel() }
    @objc private func settings() { openSettings() }
    @objc private func caffeineOff() { caffeine.deactivate() }
    @objc private func caffeineOn(_ sender: NSMenuItem) {
        if caffeine.isOn { caffeine.deactivate(announce: false) }
        caffeine.activate(minutes: sender.tag)
    }
    @objc private func toggleLogin() { engine.settings.launchAtLogin.toggle() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
