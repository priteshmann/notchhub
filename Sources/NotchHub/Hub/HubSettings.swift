import Foundation

/// App-wide settings (module toggles + General section). Module options live with each module.
struct HubSettings: Codable, Equatable, Sendable {
    /// Module id → enabled. Missing ids default to enabled.
    var enabled: [String: Bool] = [:]
    /// 0 = use the measured notch width for the idle shape.
    var idleWidthOverride: Double = 0
    /// Brief: OFF by default; v2 still targets the built-in screen only.
    var showOnAllDisplays = false
    var selectedTab: String = "focus"

    func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }

    static let key = "hub.settings"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode([String: Bool].self, forKey: .enabled)) ?? [:]
        idleWidthOverride = (try? c.decode(Double.self, forKey: .idleWidthOverride)) ?? 0
        showOnAllDisplays = (try? c.decode(Bool.self, forKey: .showOnAllDisplays)) ?? false
        selectedTab = (try? c.decode(String.self, forKey: .selectedTab)) ?? "focus"
    }
}
