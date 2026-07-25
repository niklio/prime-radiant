import Foundation
import PrimeRadiantCore

/// Model turn plumbing (pivot v3): every turn is strict `{say, patch}` JSON
/// from `claude` running on the paired box (transport in ClaudeSSHBackend);
/// malformed turns are retried (≤2) with the validator error in-context — free
/// text never corrupts the tree (handoff §5.1). Prompt assembly stays entirely
/// app-side (ContextAssembly + bundled shared/prompts/system.md).

enum ModelStreamEvent: Sendable {
    /// A fragment of the streamed model text (raw JSON characters).
    case outputTextDelta(String)
    /// The full model text at turn end (code fences already stripped).
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

enum ModelClientError: Error, Equatable {
    /// The box is beyond reach — the app rides read-only (pivot §3).
    case boxUnreachable
    /// The subscription's usage window is exhausted — "the radiant rests until
    /// the cycle renews" (pivot §3).
    case budgetExhausted
    /// The CLI reported an error turn (message passed through for the log).
    case turnFailed(String)
    case emptyResponse
    case invalidAfterRetries(String)
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
    private let config: BoxConfig

    init(backend: any ModelBackend, config: BoxConfig) {
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
        useRestructureModel: Bool = false,
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
                model: useRestructureModel ? config.restructureModel : config.interactiveModel,
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
