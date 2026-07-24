import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

/// The only auth path in the app: OpenAI's user-facing OAuth with PKCE — the
/// same account flow Codex uses (handoff §2.1). Authorization Code + PKCE via
/// ASWebAuthenticationSession, custom-scheme redirect, **no client secret
/// anywhere**. Tokens live in the Keychain (after-first-unlock, this device
/// only); refresh is proactive; revocation returns to the ignition screen.
///
/// There is NO API-key entry and no fallback auth mode, by design. If OAuth is
/// unavailable the ignition screen says so and waits.
@MainActor
@Observable
final class OpenAIAuth: NSObject {

    enum State: Equatable {
        case signedOut
        case linking
        /// `account` is the display identity from the id token, when present.
        case signedIn(account: String?)
        /// OAuth endpoint unreachable/misconfigured — ignition shows one line and waits.
        case unavailable(String)
    }

    private(set) var state: State = .signedOut

    private let config: RemoteConfig.OAuth
    private let keychain: KeychainStore
    private let urlSession: URLSession

    struct TokenSet: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date
        var account: String?
    }

    private static let tokenKey = "openai.tokens"

    init(
        config: RemoteConfig.OAuth,
        keychain: KeychainStore = KeychainStore(),
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.keychain = keychain
        self.urlSession = urlSession
        super.init()
        if let tokens = loadTokens() {
            state = .signedIn(account: tokens.account)
        }
    }

    // MARK: - Sign in (anywhere-tap on ignition → here)

    func signIn() async {
        guard state != .linking else { return }
        state = .linking
        do {
            let pkce = PKCE()
            let callbackURL = try await authenticate(pkce: pkce)
            guard
                let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                throw AuthError.missingAuthorizationCode
            }
            let tokens = try await exchange(code: code, verifier: pkce.verifier)
            try storeTokens(tokens)
            state = .signedIn(account: tokens.account)
        } catch is CancellationError {
            state = .signedOut
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            state = .signedOut
        } catch {
            // Ignition-voice error: state what happened, wait (§2.1, §10).
            state = .unavailable("sign-in is unavailable right now")
        }
    }

    /// Single Unlink action in settings (§2.1): revoke, clear, back to ignition.
    func unlink() async {
        if let tokens = loadTokens(), let revocation = config.revocationEndpoint {
            var request = URLRequest(url: revocation)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form([
                "token": tokens.refreshToken ?? tokens.accessToken,
                "client_id": config.clientId,
            ])
            _ = try? await urlSession.data(for: request)
        }
        keychain.delete(key: Self.tokenKey)
        state = .signedOut
    }

    // MARK: - Token access (proactive refresh)

    /// A valid access token for a device→OpenAI call, refreshing proactively
    /// when within two minutes of expiry. Throws (and signs out) if the refresh
    /// is rejected — revocation returns to the ignition screen (§2.1).
    func validAccessToken() async throws -> String {
        guard var tokens = loadTokens() else { throw AuthError.notSignedIn }
        if tokens.expiresAt.timeIntervalSinceNow > 120 {
            return tokens.accessToken
        }
        guard let refreshToken = tokens.refreshToken else {
            signOutLocally()
            throw AuthError.notSignedIn
        }
        do {
            let refreshed = try await requestTokens(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": config.clientId,
            ])
            tokens = refreshed
            if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
            try storeTokens(tokens)
            return tokens.accessToken
        } catch {
            signOutLocally()
            throw AuthError.refreshRejected
        }
    }

    /// Identity token for the sync Worker's /v1/auth/session (worker/src/auth.ts).
    var identityToken: String? { loadTokens()?.idToken }

    // MARK: - Internals

    private func authenticate(pkce: PKCE) async throws -> URL {
        var components = URLComponents(
            url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: PKCE.randomURLSafeString(bytes: 16)),
        ]
        let scheme = URL(string: config.redirectURI)?.scheme

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: scheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? AuthError.missingAuthorizationCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchange(code: String, verifier: String) async throws -> TokenSet {
        try await requestTokens(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientId,
            "code_verifier": verifier,
        ])
    }

    private func requestTokens(form fields: [String: String]) async throws -> TokenSet {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.tokenEndpointRejected
        }
        // TODO(M2): verify the token response shape (field names, expiry units,
        // id-token presence) against current OpenAI OAuth docs.
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenSet(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            idToken: decoded.id_token,
            expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600),
            account: Self.accountLabel(fromIdToken: decoded.id_token))
    }

    /// Best-effort display identity from the id token payload (unverified here;
    /// the sync Worker does the verification that matters).
    private static func accountLabel(fromIdToken idToken: String?) -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (payload["email"] as? String) ?? (payload["sub"] as? String)
    }

    private func loadTokens() -> TokenSet? {
        guard let data = keychain.load(key: Self.tokenKey) else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    private func storeTokens(_ tokens: TokenSet) throws {
        let data = try JSONEncoder().encode(tokens)
        try keychain.save(data, key: Self.tokenKey)
    }

    private func signOutLocally() {
        keychain.delete(key: Self.tokenKey)
        state = .signedOut
    }

    private func form(_ fields: [String: String]) -> Data {
        fields
            .map { key, value in
                let escaped = value.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics) ?? value
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    enum AuthError: Error {
        case notSignedIn
        case missingAuthorizationCode
        case tokenEndpointRejected
        case refreshRejected
    }
}

extension OpenAIAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

/// S256 code verifier/challenge (RFC 7636) via CryptoKit.
struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        verifier = Self.randomURLSafeString(bytes: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncoded
    }

    static func randomURLSafeString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
