import Foundation
import PrimeRadiantCore

/// OpenAI Responses-API client (handoff §5). Calls go **directly device→OpenAI**
/// with the user's OAuth token; no middleman ever touches conversation content
/// (§2.1). Every turn is structured output `{say, patch}`; malformed turns are
/// retried (≤2) with the validator error in-context — free text never corrupts
/// the tree (§5.1).

enum ModelStreamEvent: Sendable {
    /// A fragment of the streamed structured-output text (raw JSON characters).
    case outputTextDelta(String)
    /// The full accumulated output text at stream end.
    case completed(String)
}

struct TurnRequest: Sendable {
    var model: String
    var instructions: String
    var context: [ContextAssembly.ContextItem]
}

protocol ModelBackend: Sendable {
    func stream(_ request: TurnRequest) async throws -> AsyncThrowingStream<ModelStreamEvent, Error>
}

enum ModelClientError: Error {
    case notSignedIn
    case httpStatus(Int, body: String)
    case emptyResponse
    case invalidAfterRetries(String)
}

// MARK: - OpenAI Responses backend (SSE)

final class OpenAIResponsesBackend: ModelBackend {
    private let config: RemoteConfig.OpenAI
    /// Fresh user token per request (proactive refresh lives in OpenAIAuth).
    private let accessToken: @Sendable () async throws -> String
    private let session: URLSession

    init(
        config: RemoteConfig.OpenAI,
        accessToken: @escaping @Sendable () async throws -> String,
        session: URLSession = .shared
    ) {
        self.config = config
        self.accessToken = accessToken
        self.session = session
    }

    func stream(_ request: TurnRequest) async throws -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let token = try await accessToken()
        var urlRequest = URLRequest(
            url: config.apiBaseURL.appending(path: config.responsesPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try requestBody(for: request)

        let (bytes, response) = try await session.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2_000 { break }
            }
            throw ModelClientError.httpStatus(http.statusCode, body: body)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var accumulated = ""
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                            let event = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any],
                            let type = event["type"] as? String
                        else { continue }
                        // TODO(M2): verify current Responses SSE event names/shapes
                        // against OpenAI docs; these follow the documented
                        // `response.output_text.delta` / `response.completed` pattern.
                        switch type {
                        case "response.output_text.delta":
                            if let delta = event["delta"] as? String {
                                accumulated += delta
                                continuation.yield(.outputTextDelta(delta))
                            }
                        case "response.failed", "error":
                            throw ModelClientError.httpStatus(
                                200, body: String(describing: event))
                        case "response.completed":
                            break
                        default:
                            break
                        }
                    }
                    continuation.yield(.completed(accumulated))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func requestBody(for request: TurnRequest) throws -> Data {
        // TODO(M2): verify the structured-output request shape (`text.format`,
        // strict json_schema) on the current Responses API before ship.
        let input: [[String: Any]] = request.context.map { item in
            [
                "role": item.role.rawValue,
                "content": [["type": item.role == .assistant ? "output_text" : "input_text", "text": item.text]],
            ]
        }
        let body: [String: Any] = [
            "model": request.model,
            "instructions": request.instructions,
            "input": input,
            "stream": true,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "model_turn",
                    "strict": true,
                    "schema": ModelTurnSchema.strictSchema(),
                ]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }
}

// MARK: - Streaming `say` extraction

/// The stream carries JSON text, not prose; the human should still see `say`
/// stream live. This scanner tracks the `"say"` string literal inside the
/// accumulating JSON and emits its decoded characters incrementally.
struct SayStreamExtractor {
    private var buffer = ""
    private var emittedCount = 0

    /// Feed a delta; returns newly available prose from `say`, if any.
    mutating func consume(_ delta: String) -> String? {
        buffer += delta
        let say = Self.partialSay(in: buffer)
        guard say.count > emittedCount else { return nil }
        let fresh = String(say.dropFirst(emittedCount))
        emittedCount = say.count
        return fresh
    }

    /// Decoded value of `"say"` so far (complete or still-open string literal).
    static func partialSay(in json: String) -> String {
        guard let keyRange = json.range(of: "\"say\"") else { return "" }
        var rest = json[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return "" }
        rest = rest[rest.index(after: colon)...]
        guard let open = rest.firstIndex(of: "\"") else { return "" }

        var result = ""
        var index = rest.index(after: open)
        while index < rest.endIndex {
            let character = rest[index]
            if character == "\\" {
                let next = rest.index(after: index)
                guard next < rest.endIndex else { break }  // dangling escape mid-stream
                switch rest[next] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "u":
                    let hexEnd = rest.index(next, offsetBy: 5, limitedBy: rest.endIndex)
                    guard let hexEnd else { return result }  // incomplete \uXXXX
                    let hex = rest[rest.index(after: next)..<hexEnd]
                    if let scalarValue = UInt32(hex, radix: 16),
                        let scalar = Unicode.Scalar(scalarValue) {
                        result.append(Character(scalar))
                    }
                    index = hexEnd
                    continue
                default: break
                }
                index = rest.index(after: next)
            } else if character == "\"" {
                break  // literal closed
            } else {
                result.append(character)
                index = rest.index(after: index)
            }
        }
        return result
    }
}

// MARK: - Turn loop

/// Runs one conversational turn end to end: context assembly → streaming call →
/// validation against the live scenario → retry (≤2) with the validator error
/// in-context (§5.3).
final class ModelSession: Sendable {
    private let backend: any ModelBackend
    private let config: RemoteConfig.OpenAI

    init(backend: any ModelBackend, config: RemoteConfig.OpenAI) {
        self.backend = backend
        self.config = config
    }

    /// The shipped developer instruction (§5.2) — bundled verbatim from
    /// shared/prompts/system.md.
    static let instructions: String = {
        guard
            let url = Bundle.main.url(forResource: "system", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("shared/prompts/system.md missing from bundle")
            return ""
        }
        return text
    }()

    func runTurn(
        scenario: Scenario,
        userText: String?,
        focusedNodeId: String?,
        useReasoningModel: Bool = false,
        onSayDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModelTurn {
        var validatorFeedback: String?

        for attempt in 0...2 {
            var context = ContextAssembly.transcriptItems(scenario.transcript)
            context.append(
                ContextAssembly.ContextItem(
                    role: .system,
                    text: "current tree:\n"
                        + ContextAssembly.treeContext(
                            scenario: scenario,
                            focusedNodeId: focusedNodeId,
                            budgetBytes: config.treeContextBudgetBytes)))
            if let focusedNodeId,
                let focus = ContextAssembly.focusEvent(scenario: scenario, focusedNodeId: focusedNodeId) {
                context.append(focus)
            }
            if let position = ContextAssembly.positionEvent(scenario: scenario) {
                context.append(position)
            }
            if let userText {
                context.append(ContextAssembly.ContextItem(role: .user, text: userText))
            }
            if let validatorFeedback {
                context.append(
                    ContextAssembly.ContextItem(
                        role: .system,
                        text: "your previous output failed validation: \(validatorFeedback). "
                            + "emit a corrected {say, patch} turn."))
            }

            let request = TurnRequest(
                model: useReasoningModel ? config.reasoningModel : config.interactiveModel,
                instructions: Self.instructions,
                context: context)

            var extractor = SayStreamExtractor()
            var rawOutput = ""
            for try await event in try await backend.stream(request) {
                switch event {
                case .outputTextDelta(let delta):
                    // Only stream prose on the first attempt; retries re-stream
                    // a corrected turn from scratch.
                    if attempt == 0, let fresh = extractor.consume(delta) {
                        onSayDelta(fresh)
                    }
                case .completed(let full):
                    rawOutput = full
                }
            }
            guard !rawOutput.isEmpty else { throw ModelClientError.emptyResponse }

            switch ModelTurnValidation.validate(
                rawJSON: Data(rawOutput.utf8), against: scenario) {
            case .success(let turn):
                return turn
            case .failure(let error):
                validatorFeedback = String(describing: error)
            }
        }
        throw ModelClientError.invalidAfterRetries(validatorFeedback ?? "unknown")
    }
}
