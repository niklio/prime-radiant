import Foundation

/// HTTP/SSE client for the box-side gateway (server/README): /v1/health,
/// /v1/pair, /v1/chat (SSE), /v1/scenarios. The tailnet is the security
/// boundary; the device token distinguishes the app from other tailnet
/// traffic. Everything above the transport depends on `GatewayAPI` only, so
/// tests run against fakes and no live turn is ever spent from a test.

struct GatewayHealth: Decodable, Equatable, Sendable {
    var ok: Bool
    var version: String
    var paired: Bool
    var agentReady: Bool
    var budget: String
}

// MARK: - SSE

struct SSEEvent: Equatable, Sendable {
    var event: String
    var data: String
}

/// Incremental server-sent-events parser (event:/data: fields, blank-line
/// dispatch, `:` comment keepalives ignored). Pure; unit-tested.
struct SSEParser: Sendable {
    private var lines = LineAssembler()
    private var eventName = ""
    private var dataLines: [String] = []

    mutating func feed(_ data: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for rawLine in lines.feed(data) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if !dataLines.isEmpty || !eventName.isEmpty {
                    events.append(
                        SSEEvent(
                            event: eventName.isEmpty ? "message" : eventName,
                            data: dataLines.joined(separator: "\n")))
                }
                eventName = ""
                dataLines = []
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
            // Comment lines (": ping") and unknown fields are ignored.
        }
        return events
    }
}

// MARK: - Address candidates

enum GatewayAddress {
    /// Probe candidates for a user-entered address (MagicDNS name or 100.x):
    /// the gateway's plain port first, then tailscale-serve TLS. A full URL
    /// (from ##addr) passes through untouched.
    static func candidates(for input: String) -> [URL] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed).map { [$0] } ?? []
        }
        return [
            URL(string: "http://\(trimmed):7717"),
            URL(string: "https://\(trimmed)"),
        ].compactMap { $0 }
    }
}

// MARK: - API surface

enum GatewayError: Error, Equatable {
    case unreachable
    case invalidCode
    case pairingUnavailable
    case status(Int)
    case badResponse
}

protocol GatewayAPI: Sendable {
    /// nil = unreachable (quiet by design; the ladder decides what that means).
    func health(base: URL) async -> GatewayHealth?
    /// POST /v1/pair {code} → deviceToken (hand-installed servers only).
    func pair(base: URL, code: String) async throws -> String
    /// POST /v1/chat, SSE response.
    func chat(base: URL, token: String, body: Data) async throws
        -> AsyncThrowingStream<SSEEvent, Error>
    /// Plain JSON request against /v1/… (scenarios CRUD).
    func request(base: URL, token: String, method: String, path: String, body: Data?)
        async throws -> (status: Int, data: Data)
}

struct LiveGatewayClient: GatewayAPI {
    /// Ephemeral; the gateway is same-box infrastructure, not the web.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Short-fuse probe session: health must answer fast or the ladder moves on.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func health(base: URL) async -> GatewayHealth? {
        var request = URLRequest(url: base.appendingPathComponent("v1/health"))
        request.httpMethod = "GET"
        guard
            let (data, response) = try? await Self.probeSession.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let health = try? JSONDecoder().decode(GatewayHealth.self, from: data),
            health.ok
        else { return nil }
        return health
    }

    func pair(base: URL, code: String) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw GatewayError.unreachable
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            guard
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let token = object["deviceToken"] as? String
            else { throw GatewayError.badResponse }
            return token
        case 401:
            throw GatewayError.invalidCode
        case 403:
            throw GatewayError.pairingUnavailable
        case let status:
            throw GatewayError.status(status)
        }
    }

    func chat(base: URL, token: String, body: Data) async throws
        -> AsyncThrowingStream<SSEEvent, Error>
    {
        var request = URLRequest(url: base.appendingPathComponent("v1/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GatewayError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let (stream, continuation) = AsyncThrowingStream<SSEEvent, Error>.makeStream()
        let task = Task {
            var parser = SSEParser()
            do {
                for try await line in bytes.lines {
                    // URLSession.lines strips newlines; feed them back so the
                    // parser sees real SSE framing.
                    for event in parser.feed(Data((line + "\n").utf8)) {
                        continuation.yield(event)
                    }
                }
                // Trailing blank line may be unterminated; flush.
                for event in parser.feed(Data("\n".utf8)) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func request(
        base: URL, token: String, method: String, path: String, body: Data?
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw GatewayError.unreachable
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
