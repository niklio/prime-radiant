import Foundation

/// Runtime configuration for the OpenAI integration. Model IDs and endpoints are
/// **never hard-asserted in code** — they live here so upgrades don't require a
/// release (handoff §5.3). `fallback` ships in the binary; a remote override can
/// be fetched at launch and cached.
///
/// Every value below marked TODO(M2) must be verified against current OpenAI
/// documentation at build time — the docs win over this file (handoff preamble).
struct RemoteConfig: Codable, Sendable {

    struct OpenAI: Codable, Sendable {
        /// TODO(M2): verify against current OpenAI docs (Responses API base URL).
        var apiBaseURL: URL
        /// TODO(M2): verify the streaming Responses endpoint path.
        var responsesPath: String
        /// Fast flagship tier for interactive turns — latency matters (§5.3).
        /// TODO(M2): select the concrete model ID from current OpenAI docs.
        var interactiveModel: String
        /// Reasoning tier for complex restructures (settings toggle, §5.3).
        /// TODO(M2): select the concrete model ID from current OpenAI docs.
        var reasoningModel: String
        /// Context budget for the serialized tree before depth-4 collapse (§5.3).
        var treeContextBudgetBytes: Int
    }

    struct OAuth: Codable, Sendable {
        /// TODO(M2): verify all OAuth endpoints, scopes, and token lifetimes in
        /// OpenAI's user-facing OAuth (PKCE) docs — the same flow Codex uses (§2.1).
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var revocationEndpoint: URL?
        /// TODO(M2): the app's registered public client id (no secret — PKCE).
        var clientId: String
        /// Must match the CFBundleURLTypes scheme in project.yml.
        var redirectURI: String
        var scopes: [String]
    }

    struct Sync: Codable, Sendable {
        var baseURL: URL
    }

    var openAI: OpenAI
    var oauth: OAuth
    var sync: Sync

    static let fallback = RemoteConfig(
        openAI: OpenAI(
            apiBaseURL: URL(string: "https://api.openai.com/v1")!,
            responsesPath: "/responses",
            interactiveModel: "gpt-4.1-mini",
            reasoningModel: "o4-mini",
            treeContextBudgetBytes: 48_000),
        oauth: OAuth(
            authorizationEndpoint: URL(string: "https://auth.openai.com/oauth/authorize")!,
            tokenEndpoint: URL(string: "https://auth.openai.com/oauth/token")!,
            revocationEndpoint: URL(string: "https://auth.openai.com/oauth/revoke")!,
            clientId: "TODO-M2-client-id",
            redirectURI: "primeradiant://oauth/callback",
            scopes: ["openid", "profile", "offline_access"]),
        sync: Sync(
            baseURL: URL(string: "https://prime-radiant-sync.nikliolios.workers.dev")!))

    /// Load order: cached remote override → bundled fallback.
    /// TODO(M2): decide where the remote config document is hosted (a static KV
    /// route on the sync Worker is the obvious home) and wire the fetch + cache.
    static func load() -> RemoteConfig {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
            let cached = try? JSONDecoder().decode(RemoteConfig.self, from: data) {
            return cached
        }
        return .fallback
    }

    static func cache(_ config: RemoteConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private static let cacheKey = "prime-radiant.remote-config.v1"
}
