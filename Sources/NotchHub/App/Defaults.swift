import Foundation

/// Where NotchHub keeps its data: the UserDefaults domain `com.pritesh.notchhub`.
enum AppDefaults {
    static let suiteName = "com.pritesh.notchhub"
    static let legacySuiteName = "com.pritesh.notchpomodoro"

    /// Inside the app bundle the standard domain IS `com.pritesh.notchhub` (AppKit refuses a suite
    /// named after the app's own bundle id). A bare `swift run` binary uses the named suite instead.
    static func make() -> UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// One-time copy of the v1 Pomodoro data (settings, history, in-flight session).
    static func migrateLegacyIfNeeded(into defaults: UserDefaults) {
        let flag = "migratedFromNotchPomodoro"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard let legacy = UserDefaults(suiteName: legacySuiteName) else { return }
        for key in [PomodoroEngine.Keys.settings, PomodoroEngine.Keys.history, PomodoroEngine.Keys.inFlight]
        where defaults.object(forKey: key) == nil {
            if let data = legacy.data(forKey: key) { defaults.set(data, forKey: key) }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
