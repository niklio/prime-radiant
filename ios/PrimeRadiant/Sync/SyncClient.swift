import Foundation
import PrimeRadiantCore

/// Client for the Cloudflare sync Worker (worker/src/app.ts) at
/// https://prime-radiant-sync.nikliolios.workers.dev. Scenario sync ONLY —
/// chat traffic never touches the Worker (handoff §2.1, §6).
///
/// Sync model (§6): the client is source of truth while a scenario is open;
/// push on change, pull on open, last-write-wins on `updatedAt`. A stale PUT
/// gets 409 + the server's updatedAt; the caller pulls and keeps the newer copy.
actor SyncClient {

    struct ScenarioMetadata: Decodable, Sendable {
        let id: String
        let title: String
        let status: String
        let createdAt: String
        let updatedAt: String
    }

    enum PushResult: Sendable {
        case pushed
        /// The server copy was newer (LWW); adopt it locally.
        case superseded(Scenario)
    }

    enum SyncError: Error {
        case noIdentityToken
        case sessionRejected
        case http(Int)
        case decoding
    }

    private let baseURL: URL
    private let urlSession: URLSession
    /// Supplies the OpenAI identity token used to mint the Worker session.
    private let identityToken: @Sendable () async -> String?

    private var sessionToken: String?
    private var sessionExpiresAt: Date?

    /// Wire dates exactly as the Worker stores them (ISO-8601, fractional seconds).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }()

    init(
        baseURL: URL,
        identityToken: @escaping @Sendable () async -> String?,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.identityToken = identityToken
        self.urlSession = urlSession
    }

    // MARK: - Endpoints (mirror worker/src/app.ts)

    /// Pull-on-open: list scenario metadata for this account.
    func listScenarios() async throws -> [ScenarioMetadata] {
        let (data, _) = try await send("GET", path: "/v1/scenarios")
        struct ListResponse: Decodable { let scenarios: [ScenarioMetadata] }
        guard let decoded = try? Self.decoder.decode(ListResponse.self, from: data) else {
            throw SyncError.decoding
        }
        return decoded.scenarios
    }

    func fetchScenario(id: String) async throws -> Scenario {
        let (data, _) = try await send("GET", path: "/v1/scenarios/\(id)")
        guard let scenario = try? Self.decoder.decode(Scenario.self, from: data) else {
            throw SyncError.decoding
        }
        return scenario
    }

    /// Push-on-change. On 409 (stale write) the server's newer copy wins:
    /// fetch it and hand it back for local adoption.
    func push(_ scenario: Scenario) async throws -> PushResult {
        let body = try Self.encoder.encode(scenario)
        do {
            _ = try await send("PUT", path: "/v1/scenarios/\(scenario.id)", body: body)
            return .pushed
        } catch SyncError.http(409) {
            let server = try await fetchScenario(id: scenario.id)
            return .superseded(server)
        }
    }

    /// Soft delete (30-day purge server-side); backs the DELETE well.
    func delete(id: String) async throws {
        _ = try await send("DELETE", path: "/v1/scenarios/\(id)")
    }

    /// Undo for the delete toast.
    func restore(id: String) async throws {
        _ = try await send("POST", path: "/v1/scenarios/\(id)/restore")
    }

    // MARK: - Session (/v1/auth/session)

    private func ensureSession() async throws -> String {
        if let token = sessionToken, let expiry = sessionExpiresAt,
            expiry.timeIntervalSinceNow > 60 {
            return token
        }
        guard let identity = await identityToken() else { throw SyncError.noIdentityToken }
        var request = URLRequest(url: baseURL.appending(path: "/v1/auth/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["identityToken": identity])
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.sessionRejected
        }
        struct SessionResponse: Decodable {
            let token: String
            let expiresAt: String
        }
        guard let decoded = try? JSONDecoder().decode(SessionResponse.self, from: data) else {
            throw SyncError.decoding
        }
        sessionToken = decoded.token
        sessionExpiresAt =
            ISO8601DateFormatter().date(from: decoded.expiresAt)
            ?? Date().addingTimeInterval(3600)
        return decoded.token
    }

    private func send(
        _ method: String, path: String, body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let token = try await ensureSession()
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.decoding }
        if http.statusCode == 401 {
            // Session expired server-side; mint a fresh one and retry once.
            sessionToken = nil
            let retryToken = try await ensureSession()
            var retry = request
            retry.setValue("Bearer \(retryToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await urlSession.data(for: retry)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw SyncError.decoding
            }
            guard (200..<300).contains(retryHTTP.statusCode) else {
                throw SyncError.http(retryHTTP.statusCode)
            }
            return (retryData, retryHTTP)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.http(http.statusCode)
        }
        return (data, http)
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = isoFormatter.date(from: string) ?? isoBasicFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid ISO-8601 date: \(string)")
        }
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoBasicFormatter = ISO8601DateFormatter()
