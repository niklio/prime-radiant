import Foundation
import PrimeRadiantCore

/// `TurnEngine` over the gateway's POST /v1/chat SSE (server/README chat
/// contract): the app assembles the same context the SSH path sends; the
/// gateway assembles the prompt, holds the warm claude process, validates the
/// turn server-side (ajv, ≤2 retries) and streams:
///
///   say   {"text": …}          → live prose deltas
///   turn  {say, patch}         → the validated turn
///   error {"error": "budget_resting" | "invalid_turn" | "turn_failed", …}
///   done  {}
///
/// The client still re-validates the turn against the live scenario
/// (ModelTurnValidation) — the server's validation is authoritative for shape,
/// the client's dry-run remains the second check against the current tree.
struct GatewayTurnEngine: TurnEngine {
    let gateway: any GatewayAPI
    let base: URL
    let token: String
    let config: BoxConfig

    /// Transport-level failure (network, HTTP status): the router falls back
    /// to SSH quietly. Turn-level errors (rest, invalid) propagate as-is.
    struct TransportFailure: Error {}

    func runTurn(
        scenario: Scenario,
        userText: String?,
        focusedNodeId: String?,
        useRestructureModel: Bool,
        onSayDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModelTurn {
        let context = ModelSession.assembleContext(
            scenario: scenario,
            userText: userText,
            focusedNodeId: focusedNodeId,
            treeContextBudgetBytes: config.treeContextBudgetBytes)

        var body: [String: Any] = [
            "scenarioId": scenario.id,
            "mode": useRestructureModel ? "restructure" : "interactive",
            "context": context.map { ["role": $0.role.rawValue, "text": $0.text] },
            "systemPrompt": ModelSession.instructions,
        ]
        if let focusedNodeId { body["focusedNodeId"] = focusedNodeId }
        let payload = try JSONSerialization.data(withJSONObject: body)

        let events: AsyncThrowingStream<SSEEvent, Error>
        do {
            events = try await gateway.chat(base: base, token: token, body: payload)
        } catch {
            throw TransportFailure()
        }

        var turnData: Data?
        var turnError: ModelClientError?
        do {
            for try await event in events {
                switch event.event {
                case "say":
                    if let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8))
                        as? [String: Any],
                        let text = object["text"] as? String {
                        onSayDelta(text)
                    }
                case "turn":
                    turnData = Data(event.data.utf8)
                case "error":
                    turnError = Self.mapError(event.data)
                case "done":
                    break
                default:
                    break
                }
            }
        } catch {
            // The stream broke mid-turn — a transport problem, not a turn one.
            if turnData == nil && turnError == nil { throw TransportFailure() }
        }

        if let turnError { throw turnError }
        guard let turnData else { throw ModelClientError.emptyResponse }

        // Second check: dry-run the validated turn against the live scenario.
        switch ModelTurnValidation.validate(rawJSON: turnData, against: scenario) {
        case .success(let turn):
            return turn
        case .failure(let error):
            throw ModelClientError.invalidAfterRetries(String(describing: error))
        }
    }

    static func mapError(_ data: String) -> ModelClientError {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(data.utf8))
                as? [String: Any],
            let code = object["error"] as? String
        else { return .turnFailed("gateway error") }
        switch code {
        case "budget_resting":
            return .budgetExhausted
        case "invalid_turn":
            return .invalidAfterRetries((object["message"] as? String) ?? "invalid turn")
        default:
            return .turnFailed((object["message"] as? String) ?? code)
        }
    }
}

/// Transport-aware turn routing: gateway when the ladder says gateway, SSH
/// otherwise; a gateway *transport* failure falls back to SSH mid-call and
/// tells the ladder, quietly (no dialogs — pivot §3).
struct RoutedTurnEngine: TurnEngine {
    let transport: @MainActor @Sendable () -> ActiveTransport
    let gatewayEngine: @MainActor @Sendable () -> GatewayTurnEngine?
    let sshEngine: ModelSession
    let onGatewayFailure: @MainActor @Sendable () -> Void

    func runTurn(
        scenario: Scenario,
        userText: String?,
        focusedNodeId: String?,
        useRestructureModel: Bool,
        onSayDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModelTurn {
        let active = await transport()
        if active == .gateway, let engine = await gatewayEngine() {
            do {
                return try await engine.runTurn(
                    scenario: scenario, userText: userText, focusedNodeId: focusedNodeId,
                    useRestructureModel: useRestructureModel, onSayDelta: onSayDelta)
            } catch is GatewayTurnEngine.TransportFailure {
                await onGatewayFailure()
                // Fall through to SSH, quietly.
            }
        }
        return try await sshEngine.runTurn(
            scenario: scenario, userText: userText, focusedNodeId: focusedNodeId,
            useRestructureModel: useRestructureModel, onSayDelta: onSayDelta)
    }
}
