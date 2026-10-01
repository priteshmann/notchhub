import AppKit
import UserNotifications

/// User notifications + the end-of-session sound. Authorization is requested lazily, the first
/// time a focus session starts, never at launch.
@MainActor
final class Notifier {
    private var requested = false

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. a bare `swift run`).
    private var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func requestAuthorizationIfNeeded() {
        guard canNotify, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sessionEnded(finished: Phase, next: Phase, settings: PomodoroSettings) {
        if settings.soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        switch finished {
        case .focus:
            content.title = "Focus done — take \(settings.minutes(for: next))"
            content.body = next == .longBreak ? "Long break earned." : "Short break."
        case .shortBreak, .longBreak:
            content.title = "Break over — back to focus"
            content.body = "\(settings.focusMinutes) minutes of focus next."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
