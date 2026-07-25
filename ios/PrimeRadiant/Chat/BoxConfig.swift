import Foundation

/// Runtime configuration for the claude-over-SSH integration (pivot v3,
/// RemoteConfig's successor). Model aliases are **never hardcoded in views** —
/// they live here; the `claude` CLI resolves an alias to the current model on
/// the box, so upgrades require neither a release nor a config push.
struct BoxConfig: Codable, Sendable {
    /// Fast alias for interactive turns — latency matters (handoff §5.3).
    var interactiveModel: String
    /// Top-model alias for complex restructures (settings toggle, §5.3).
    var restructureModel: String
    /// Context budget for the serialized tree before depth-4 collapse (§5.3).
    var treeContextBudgetBytes: Int

    static let fallback = BoxConfig(
        interactiveModel: "sonnet",
        restructureModel: "opus",
        treeContextBudgetBytes: 48_000)

    /// Load order: cached local override → bundled fallback.
    static func load() -> BoxConfig {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
            let cached = try? JSONDecoder().decode(BoxConfig.self, from: data) {
            return cached
        }
        return .fallback
    }

    static func cache(_ config: BoxConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private static let cacheKey = "prime-radiant.box-config.v1"
}
