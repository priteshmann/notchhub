import AppKit
import Combine
import SwiftUI

/// Module 2: Spotify + Apple Music via AppleScript. Polls every 2 s while a player runs and the
/// panel is open, 5 s otherwise, and not at all when neither player is running.
@MainActor
final class NowPlayingModule: ObservableObject, NotchModule {
    enum Preference: String, Codable, Sendable, CaseIterable {
        case automatic, spotify, music

        var label: String {
            switch self {
            case .automatic: return "Automatic (whichever is playing)"
            case .spotify: return "Spotify only"
            case .music: return "Music only"
            }
        }
    }

    struct Settings: Codable, Equatable, Sendable {
        var preference: Preference = .automatic
        /// Set once the Automation prompt has been triggered (first use of the tab) or found granted.
        var consentRequested = false
    }

    enum Status: Equatable {
        case noPlayer, needsConsent, denied(Player), ready
    }

    let id = "nowPlaying"
    let title = "Now Playing"
    let systemImage = "music.note"
    let panelHeight: CGFloat = 130
    var collapsedWingWidth: CGFloat { 40 }

    @Published private(set) var track: TrackState?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var status: Status = .noPlayer
    @Published var settings: Settings {
        didSet {
            AppDefaults.encode(settings, to: defaults, key: "nowPlaying.settings")
            if settings.preference != oldValue.preference { reschedule() }
        }
    }
    /// Local slider values while dragging (sent on release).
    @Published var scrubPosition: Double?
    @Published var scrubVolume: Double?

    private let defaults: UserDefaults
    private let runner = AppleScriptRunner()
    private var timer: Timer?
    private var running = false
    private var panelVisible = false
    private var polling = false
    private var observers: [NSObjectProtocol] = []
    private var artworkKey: String?
    private var artworkCache: [String: NSImage] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = AppDefaults.decode(Settings.self, from: defaults, key: "nowPlaying.settings") ?? Settings()
    }

    // MARK: Lifecycle

    func start() {
        running = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reschedule() }
            })
        }
        reschedule()
    }

    func stop() {
        running = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        track = nil
    }

    func visibilityChanged(expanded: Bool, selected: Bool) {
        var changed = false
        if selected, !settings.consentRequested, !candidates.isEmpty {
            // First use of the tab: the next poll triggers the Automation prompt.
            settings.consentRequested = true
            changed = true
        }
        if panelVisible != expanded {
            panelVisible = expanded
            changed = true
        }
        if changed { reschedule() }
    }

    /// Players we may talk to, filtered by preference and by what is running right now.
    private var candidates: [Player] {
        let allowed: [Player]
        switch settings.preference {
        case .automatic: allowed = [.spotify, .music]
        case .spotify: allowed = [.spotify]
        case .music: allowed = [.music]
        }
        return allowed.filter(\.isRunning)
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        let players = candidates
        guard !players.isEmpty else {
            if track != nil { track = nil }
            artwork = nil
            artworkKey = nil
            status = .noPlayer
            return
        }
        guard settings.consentRequested else {
            status = .needsConsent
            checkExistingConsent(players)
            return
        }
        let interval: TimeInterval = panelVisible ? 2 : 5
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    /// If Automation was already granted (System Settings), skip the "first use" gate.
    private func checkExistingConsent(_ players: [Player]) {
        Task { @MainActor [weak self, runner] in
            for p in players where await runner.isAutomationGranted(bundleID: p.bundleID) {
                self?.settings.consentRequested = true
                self?.reschedule()
                return
            }
        }
    }

    func connect() {
        settings.consentRequested = true
        reschedule()
    }

    // MARK: Polling

    private func poll() {
        guard !polling else { return }
        polling = true
        let players = candidates
        Task { @MainActor [weak self, runner] in
            var outcomes: [PollOutcome] = []
            var denied: Player?
            for p in players {
                let result = await runner.run(PlayerScripts.poll(p)) { d in
                    PlayerScripts.parse(d, player: p, now: Date())
                }
                switch result {
                case .success(let o): outcomes.append(o)
                case .failure(.notPermitted): denied = p
                case .failure: break
                }
            }
            self?.apply(outcomes, denied: denied)
        }
    }

    private func apply(_ outcomes: [PollOutcome], denied: Player?) {
        polling = false
        let tracks = outcomes.compactMap { o -> TrackState? in
            if case .track(let t) = o { return t }
            return nil
        }
        // Prefer a playing player, then the one we showed last, then any.
        let chosen = tracks.first(where: \.isPlaying)
            ?? tracks.first(where: { $0.player == track?.player })
            ?? tracks.first
        if let chosen {
            status = .ready
            if track != chosen { track = chosen }
            loadArtwork(for: chosen)
        } else {
            track = nil
            artwork = nil
            artworkKey = nil
            if let denied { status = .denied(denied) } else { status = .ready }
        }
    }

    private func loadArtwork(for t: TrackState) {
        guard artworkKey != t.trackKey else { return }
        artworkKey = t.trackKey
        if t.player == .spotify, let urlString = t.artworkURL {
            if let cached = artworkCache[urlString] { artwork = cached; return }
            artwork = nil
            guard let url = URL(string: urlString) else { return }
            Task { @MainActor [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { return }
                self?.cacheArtwork(image, key: urlString, trackKey: t.trackKey)
            }
        } else if t.player == .music {
            artwork = nil
            Task { @MainActor [weak self, runner] in
                let result = await runner.run(PlayerScripts.musicArtwork()) { d in d.data }
                guard case .success(let data) = result, !data.isEmpty, let image = NSImage(data: data) else { return }
                self?.cacheArtwork(image, key: nil, trackKey: t.trackKey)
            }
        } else {
            artwork = nil
        }
    }

    private func cacheArtwork(_ image: NSImage, key: String?, trackKey: String) {
        if let key {
            if artworkCache.count > 30 { artworkCache.removeAll() }
            artworkCache[key] = image
        }
        if artworkKey == trackKey { artwork = image }
    }

    // MARK: Commands

    private func send(_ body: String) {
        guard let player = track?.player ?? candidates.first else { return }
        Task { @MainActor [weak self, runner] in
            _ = await runner.run(PlayerScripts.command(player, body)) { _ in true }
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.poll()
        }
    }

    func playPause() {
        if var t = track { t.isPlaying.toggle(); track = t }  // optimistic
        send("playpause")
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        if var t = track {
            t.position = seconds
            t.fetchedAt = Date()
            track = t
        }
        send("set player position to \(Int(seconds.rounded()))")
    }

    func setVolume(_ v: Double) {
        if var t = track { t.volume = v; track = t }
        send("set sound volume to \(Int(v.rounded()))")
    }

    /// Wall-clock interpolation between polls.
    func position(at date: Date) -> Double {
        guard let t = track else { return 0 }
        let elapsed = t.isPlaying ? date.timeIntervalSince(t.fetchedAt) : 0
        return min(t.duration, max(0, t.position + elapsed))
    }

    // MARK: Views

    var collapsedPriority: Int {
        track?.isPlaying == true ? CollapsedPriority.nowPlayingPlaying : CollapsedPriority.nowPlayingPaused
    }

    var collapsedView: AnyView? {
        guard track != nil else { return nil }
        return AnyView(NowPlayingCollapsedView(module: self))
    }

    var expandedView: AnyView { AnyView(NowPlayingView(module: self)) }
    var settingsView: AnyView { AnyView(NowPlayingSettingsView(module: self)) }
}
