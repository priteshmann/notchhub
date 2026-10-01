import AppKit
import Foundation

enum Player: String, Codable, Sendable, CaseIterable {
    case spotify, music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    var appName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        }
    }

    /// Never launches the player: only looks at what is already running.
    @MainActor
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct TrackState: Equatable, Sendable {
    var player: Player
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    /// Seconds.
    var duration: Double
    /// Seconds, as of `fetchedAt`.
    var position: Double
    /// 0...100 (player volume).
    var volume: Double
    var artworkURL: String?
    /// Identity of the track (changes when the track changes).
    var trackKey: String
    var fetchedAt: Date
}

enum ScriptError: Error, Equatable, Sendable {
    /// errAEEventNotPermitted (-1743): the user said no under Privacy & Security › Automation.
    case notPermitted
    case failed(Int, String)
}

enum PollOutcome: Sendable, Equatable {
    case track(TrackState)
    case stopped(Player)
    case notRunning(Player)
}

/// Runs AppleScript on one private serial queue (NSAppleScript is not thread-safe, and a first
/// Automation prompt blocks the sending thread: it must never be the main thread).
final class AppleScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pritesh.notchhub.applescript", qos: .userInitiated)
    /// Compiled scripts, touched only on `queue`.
    private var cache: [String: NSAppleScript] = [:]

    func run<T: Sendable>(_ source: String,
                          parse: @escaping @Sendable (NSAppleEventDescriptor) -> T) async -> Result<T, ScriptError> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.execute(source, parse: parse))
            }
        }
    }

    private func execute<T>(_ source: String, parse: (NSAppleEventDescriptor) -> T) -> Result<T, ScriptError> {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let made = NSAppleScript(source: source) else { return .failure(.failed(0, "bad script")) }
            script = made
            cache[source] = made
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            return .failure(code == -1743 ? .notPermitted : .failed(code, message))
        }
        return .success(parse(result))
    }

    /// Automation consent for `bundleID` without prompting: true = already granted.
    func isAutomationGranted(bundleID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                guard let desc = target.aeDesc else { continuation.resume(returning: false); return }
                let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
                continuation.resume(returning: status == noErr)
            }
        }
    }
}

/// The AppleScript for each player. Every script checks `is running` first so it can never
/// launch the player.
enum PlayerScripts {
    static func poll(_ p: Player) -> String {
        let durationExpr = p == .spotify ? "(duration of t) / 1000" : "duration of t"
        let artExpr = p == .spotify ? "artwork url of t" : "\"\""
        let idExpr = p == .spotify ? "id of t" : "persistent ID of t"
        return """
        if application id "\(p.bundleID)" is running then
            tell application id "\(p.bundleID)"
                set st to player state as string
                if st is "stopped" then return {"stopped"}
                set t to current track
                return {st, name of t, artist of t, album of t, \(durationExpr), player position, sound volume, \(artExpr), \(idExpr)}
            end tell
        end if
        return {"notrunning"}
        """
    }

    static func command(_ p: Player, _ body: String) -> String {
        """
        if application id "\(p.bundleID)" is running then
            tell application id "\(p.bundleID)" to \(body)
        end if
        """
    }

    static func musicArtwork() -> String {
        """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
                try
                    return raw data of artwork 1 of current track
                on error
                    try
                        return data of artwork 1 of current track
                    end try
                end try
            end tell
        end if
        return ""
        """
    }

    /// Parses the poll list. Number formatting never matters: descriptors carry typed values.
    static func parse(_ d: NSAppleEventDescriptor, player: Player, now: Date) -> PollOutcome {
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        let state = str(1)
        if state == "notrunning" { return .notRunning(player) }
        if state == "stopped" || d.numberOfItems < 9 { return .stopped(player) }
        let art = str(8)
        return .track(TrackState(player: player, isPlaying: state == "playing",
                                 title: str(2), artist: str(3), album: str(4),
                                 duration: max(0, num(5)), position: max(0, num(6)), volume: num(7),
                                 artworkURL: art.isEmpty ? nil : art,
                                 trackKey: "\(player.rawValue):\(str(9)):\(str(2))",
                                 fetchedAt: now))
    }
}
