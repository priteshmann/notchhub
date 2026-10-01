import Combine
import SwiftUI

/// One feature of the hub. Modules are ObservableObjects; the hub republishes their changes.
@MainActor
protocol NotchModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var systemImage: String { get }
    /// Higher wins the collapsed bar. Only consulted when `collapsedView` is non-nil.
    var collapsedPriority: Int { get }
    /// Collapsed bar content (use `WingsBar`); nil = nothing to show.
    var collapsedView: AnyView? { get }
    /// Width of each wing beside the notch when this module owns the collapsed bar.
    var collapsedWingWidth: CGFloat { get }
    var expandedView: AnyView { get }
    /// Height of the expanded body below the tab strip.
    var panelHeight: CGFloat { get }
    /// Width of the expanded panel while this module's tab is selected.
    var panelWidth: CGFloat { get }
    /// False for header-only modules (Battery, Caffeine).
    var showsTab: Bool { get }
    /// Item for the header strip, if any, and where it sits.
    var headerView: AnyView? { get }
    var headerPlacement: HeaderPlacement { get }
    /// This module's section in the Settings window (without the enable toggle).
    var settingsView: AnyView { get }
    var changes: AnyPublisher<Void, Never> { get }

    func start()
    func stop()
    /// Called whenever the panel opens/closes or the selected tab changes.
    func visibilityChanged(expanded: Bool, selected: Bool)
}

extension NotchModule {
    var collapsedPriority: Int { 0 }
    var collapsedView: AnyView? { nil }
    var collapsedWingWidth: CGFloat { 110 }
    var showsTab: Bool { true }
    var panelWidth: CGFloat { HubStore.expandedWidth }
    var headerView: AnyView? { nil }
    var headerPlacement: HeaderPlacement { .right }
    func visibilityChanged(expanded: Bool, selected: Bool) {}
}

extension NotchModule where Self: ObservableObject, Self.ObjectWillChangePublisher == ObservableObjectPublisher {
    var changes: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }
}

/// Header strip slots: the wings beside the notch (left / right) or the right end of the tab row.
enum HeaderPlacement: Sendable {
    case left, right, tabRow
}

/// Collapsed priorities (brief: transient > Pomodoro running > Now Playing > idle).
enum CollapsedPriority {
    static let focusRunning = 100
    static let nowPlayingPlaying = 60
    static let focusPaused = 40
    static let nowPlayingPaused = 20
}

/// Notch metrics for views that lay out around the notch.
private struct NotchWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 179
}

extension EnvironmentValues {
    var notchWidth: CGFloat {
        get { self[NotchWidthKey.self] }
        set { self[NotchWidthKey.self] = newValue }
    }
}

/// Left wing | notch gap | right wing.
struct WingsBar<Left: View, Right: View>: View {
    var wingWidth: CGFloat
    var left: Left
    var right: Right
    @Environment(\.notchWidth) private var notchWidth

    init(wingWidth: CGFloat, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.wingWidth = wingWidth
        self.left = left()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: wingWidth)
            Color.clear.frame(width: notchWidth)
            right.frame(width: wingWidth)
        }
    }
}

/// How modules raise a collapsed overlay without knowing about the hub.
typealias TransientSink = @MainActor (Transient) -> Void
