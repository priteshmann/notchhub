import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: PomodoroEngine?
    private var hub: HubStore?
    private var notchWindow: NotchWindowController?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var hotkeys: [Hotkey] = []
    private var debugDriver: DebugDriver?
    private let notifier = Notifier()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = AppDefaults.make()
        AppDefaults.migrateLegacyIfNeeded(into: defaults)

        let engine = PomodoroEngine(defaults: defaults)
        self.engine = engine
        let hub = HubStore(defaults: defaults)
        self.hub = hub
        let notify: TransientSink = { [weak hub] t in hub?.show(t) }

        let focus = FocusModule(engine: engine)
        let caffeine = CaffeineModule(defaults: defaults, notify: notify)
        let battery = BatteryModule(defaults: defaults, notify: notify)
        let notes = NotesModule(defaults: defaults, notify: notify)
        let clipboard = ClipboardModule(defaults: defaults, notify: notify)
        let shelf = ShelfModule(defaults: defaults, notify: notify) { [weak hub] active in
            active ? hub?.dragOutBegan() : hub?.dragOutEnded()
        }
        let calendar = CalendarModule(defaults: defaults)
        let nowPlaying = NowPlayingModule(defaults: defaults)
        let mirror = MirrorModule()
        let modules: [any NotchModule] = [
            focus,
            nowPlaying,
            shelf,
            clipboard,
            notes,
            calendar,
            mirror,
            battery,
            caffeine,
        ]
        hub.register(modules)

        engine.onPhaseComplete = { [weak self, weak engine, weak hub] finished, next in
            guard let self, let engine else { return }
            self.notifier.sessionEnded(finished: finished, next: next, settings: engine.settings)
            hub?.flash(PhaseColors.color(finished))
        }
        // Notifications: asked the first time a session runs, not at launch.
        engine.$isRunning
            .filter { $0 }
            .first()
            .sink { [weak self] _ in self?.notifier.requestAuthorizationIfNeeded() }
            .store(in: &cancellables)

        let settings = SettingsWindowController(hub: hub, engine: engine)
        settingsWindow = settings

        let window = NotchWindowController(hub: hub) { [weak settings] in settings?.show() }
        window.onFileDrop = { [weak shelf] urls in shelf?.add(urls) }
        window.show()
        notchWindow = window

        let status = StatusItemController(engine: engine, caffeine: caffeine, hub: hub,
                                          openPanel: { [weak window] in window?.expand(byHover: false) },
                                          openSettings: { [weak settings] in settings?.show() })
        statusItem = status
        window.contextMenuProvider = { [weak status] in status?.makeMenu() }

        hotkeys = [
            Hotkey.pomodoro { [weak engine] in engine?.toggle() },
            Hotkey.panel { [weak window] in window?.toggleExpanded() },
        ].compactMap { $0 }

        debugDriver = DebugDriver.startIfEnabled(
            defaults: defaults,
            targets: .init(hub: hub, window: window, engine: engine, caffeine: caffeine,
                           clipboard: clipboard, notes: notes))

        syncLaunchAtLogin(engine)
        engine.$settings
            .map(\.launchAtLogin)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in self?.applyLaunchAtLogin(enabled) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.forEach { $0.unregister() }
        hub?.stopAll()
    }

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// If the user changed the login item in System Settings, reflect that in our setting.
    private func syncLaunchAtLogin(_ engine: PomodoroEngine) {
        guard isBundled else { return }
        let enabled = SMAppService.mainApp.status == .enabled
        if engine.settings.launchAtLogin != enabled {
            engine.settings.launchAtLogin = enabled
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard isBundled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("NotchHub: launch at login change failed: \(error.localizedDescription)")
        }
    }
}
