import Combine
import SwiftUI

/// Owns the module list, the selected tab, the transient queue and the panel's UI state.
@MainActor
final class HubStore: ObservableObject {
    static let expandedWidth: CGFloat = 400
    static let tabStripHeight: CGFloat = 26
    /// Concave fillets where the shape meets the screen's top edge (not drawn when idle).
    static let filletRadius: CGFloat = 6
    static let transientWingWidth: CGFloat = 120
    /// Narrowest header wing beside the notch when expanded (400 pt total on a 179 pt notch).
    static let headerWingMinWidth: CGFloat = 110

    enum Collapsed {
        case idle
        case transient(Transient)
        case module(any NotchModule)
    }

    @Published private(set) var modules: [any NotchModule] = []
    @Published var settings: HubSettings {
        didSet {
            AppDefaults.encode(settings, to: defaults, key: HubSettings.key)
            if settings.enabled != oldValue.enabled { applyEnabledStates() }
        }
    }
    @Published var expanded = false {
        didSet { if expanded != oldValue { notifyVisibility() } }
    }
    @Published var notchWidth: CGFloat = 200
    @Published var notchHeight: CGFloat = 32
    @Published private(set) var transient: Transient?
    /// Session-end flash. Lives here, not in `@State`: the SwiftUI `@State` macro plugin is not
    /// shipped with the Command Line Tools.
    @Published var flashOn = false
    @Published private(set) var flashColor: Color = .clear

    private let defaults: UserDefaults
    private let now: () -> Date
    private var queue = TransientQueue()
    private var transientTask: Task<Void, Never>?
    private var running: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        settings = AppDefaults.decode(HubSettings.self, from: defaults, key: HubSettings.key) ?? HubSettings()
    }

    // MARK: Modules

    func register(_ list: [any NotchModule]) {
        modules = list
        for module in list {
            module.changes
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        applyEnabledStates()
    }

    func module(_ id: String) -> (any NotchModule)? { modules.first { $0.id == id } }

    func isEnabled(_ id: String) -> Bool { settings.isEnabled(id) }

    func setEnabled(_ id: String, _ on: Bool) { settings.enabled[id] = on }

    var enabledModules: [any NotchModule] { modules.filter { isEnabled($0.id) } }

    var visibleTabs: [any NotchModule] { enabledModules.filter(\.showsTab) }

    var headerModules: [any NotchModule] { enabledModules.filter { $0.headerView != nil } }

    var selectedModule: (any NotchModule)? {
        let tabs = visibleTabs
        return tabs.first { $0.id == settings.selectedTab } ?? tabs.first
    }

    func select(_ id: String) {
        guard settings.selectedTab != id else { return }
        settings.selectedTab = id
        notifyVisibility()
    }

    /// Stop disabled modules, start newly enabled ones.
    private func applyEnabledStates() {
        for module in modules {
            let on = isEnabled(module.id)
            if on, !running.contains(module.id) {
                running.insert(module.id)
                module.start()
            } else if !on, running.contains(module.id) {
                running.remove(module.id)
                module.stop()
            }
        }
        notifyVisibility()
    }

    func stopAll() {
        for module in modules where running.contains(module.id) { module.stop() }
        running.removeAll()
    }

    private func notifyVisibility() {
        let selectedID = selectedModule?.id
        for module in enabledModules {
            module.visibilityChanged(expanded: expanded, selected: expanded && module.id == selectedID)
        }
    }

    // MARK: Transients

    func show(_ t: Transient) {
        queue.enqueue(t, now: now())
        refreshTransient()
    }

    private func refreshTransient() {
        let head = queue.current(now: now())
        if head != transient {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { transient = head }
        }
        transientTask?.cancel()
        guard let expiry = queue.nextExpiry else { return }
        let delay = max(0.05, expiry.timeIntervalSince(now()))
        transientTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshTransient()
        }
    }

    // MARK: Flash

    func flash(_ color: Color) {
        flashColor = color
        Task { @MainActor [weak self] in
            for _ in 0..<3 {
                withAnimation(.easeInOut(duration: 0.18)) { self?.flashOn = true }
                try? await Task.sleep(nanoseconds: 250_000_000)
                withAnimation(.easeInOut(duration: 0.18)) { self?.flashOn = false }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    // MARK: Layout

    var collapsed: Collapsed {
        if let transient { return .transient(transient) }
        let owner = enabledModules
            .filter { $0.collapsedView != nil }
            .max { $0.collapsedPriority < $1.collapsedPriority }
        if let owner { return .module(owner) }
        return .idle
    }

    var idleWidth: CGFloat {
        settings.idleWidthOverride > 0 ? CGFloat(settings.idleWidthOverride) : notchWidth
    }

    var isIdle: Bool {
        if expanded { return false }
        if case .idle = collapsed { return true }
        return false
    }

    var collapsedWingWidth: CGFloat {
        switch collapsed {
        case .idle: return 0
        case .transient: return Self.transientWingWidth
        case .module(let m): return m.collapsedWingWidth
        }
    }

    var bodyHeight: CGFloat { selectedModule?.panelHeight ?? 120 }

    var fillet: CGFloat { fillet(expanded: expanded) }

    func fillet(expanded: Bool) -> CGFloat {
        if expanded { return Self.filletRadius }
        if case .idle = collapsed { return 0 }
        return Self.filletRadius
    }

    var contentSize: CGSize { contentSize(expanded: expanded) }

    /// Size of the black shape's content box (fillets excluded).
    func contentSize(expanded: Bool) -> CGSize {
        if expanded {
            let width = max(Self.expandedWidth, notchWidth + 2 * Self.headerWingMinWidth)
            return CGSize(width: width, height: notchHeight + Self.tabStripHeight + bodyHeight)
        }
        if case .idle = collapsed {
            return CGSize(width: idleWidth, height: notchHeight)
        }
        return CGSize(width: notchWidth + 2 * collapsedWingWidth, height: notchHeight)
    }

    var shapeSize: CGSize { shapeSize(expanded: expanded) }

    /// The black shape's size including the fillets on both sides. The hover rect IS this.
    func shapeSize(expanded: Bool) -> CGSize {
        let c = contentSize(expanded: expanded)
        return CGSize(width: c.width + 2 * fillet(expanded: expanded), height: c.height)
    }

    // MARK: Drag-out (Shelf) keeps the panel open until the drag session ends.

    private(set) var dragOutActive = false

    /// Set by the window controller: grows the panel first, then expands.
    var expandHandler: (() -> Void)?

    func requestExpand() {
        if let expandHandler { expandHandler() } else { expanded = true }
    }

    func dragOutBegan() { dragOutActive = true }
    func dragOutEnded() { dragOutActive = false }
}
