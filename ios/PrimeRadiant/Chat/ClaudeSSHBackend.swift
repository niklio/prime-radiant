import Foundation

/// `ModelBackend` over the paired box's SSH exec channel (pivot v3): the app
/// execs the `claude` CLI in streaming JSON print mode through a login shell.
/// A **warm process per scenario session** (stream-json stdin) avoids per-turn
/// cold starts; if the warm channel died, the turn falls back to a one-shot
/// `claude -p`. All inference goes through the official CLI — no tokens are
/// ever extracted or replayed against the API (pivot §5).
///
/// Stream-json shapes (verified against claude CLI 2.1.178):
/// - `{"type":"stream_event","event":{"type":"content_block_delta","delta":
///    {"type":"text_delta","text":"…"}}}` — model text fragments. Other delta
///    kinds (`thinking_delta`, `signature_delta`) are filtered out.
/// - `{"type":"result","subtype":"success","is_error":false,"result":"…"}` —
///    turn end, full text. A warm session emits one per stdin user message.
actor ClaudeSSHBackend: ModelBackend {

    private let box: any SSHBox
    /// Reconnect-on-drop hook (BoxSession.ensureConnected).
    private let ensureConnected: @Sendable () async -> Bool

    init(box: any SSHBox, ensureConnected: @escaping @Sendable () async -> Bool) {
        self.box = box
        self.ensureConnected = ensureConnected
    }

    // MARK: - ModelBackend

    func stream(_ request: TurnRequest) async throws -> AsyncThrowingStream<ModelStreamEvent, Error> {
        guard await ensureConnected() else { throw ModelClientError.boxUnreachable }
        let prompt = Self.prompt(for: request)
        let (stream, continuation) = AsyncThrowingStream<ModelStreamEvent, Error>.makeStream()
        let task = Task {
            do {
                try await self.runTurn(model: request.model, prompt: prompt) {
                    continuation.yield($0)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runTurn(
        model: String, prompt: String, yield: @escaping (ModelStreamEvent) -> Void
    ) async throws {
        if try await warmTurn(model: model, prompt: prompt, yield: yield) {
            return
        }
        try await oneShotTurn(model: model, prompt: prompt, yield: yield)
    }

    // MARK: - Warm session (one long-lived claude process per scenario)

    /// Actor-confined warm channel state; a pump task pushes output back into
    /// the actor so no iterator ever leaves isolation.
    private final class Warm {
        let id = UUID()
        let channel: ExecChannel
        let model: String
        var lines = LineAssembler()
        var stderr = ""
        var pump: Task<Void, Never>?

        init(channel: ExecChannel, model: String) {
            self.channel = channel
            self.model = model
        }
    }

    /// The in-flight turn (one at a time; ScenarioStore serializes sends).
    private struct TurnState {
        let yield: (ModelStreamEvent) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct WarmDied: Error {}

    private var warm: Warm?
    private var turn: TurnState?

    /// Returns true when the turn completed on the warm channel; false means
    /// the channel was (or went) dead and the caller should fall back to a
    /// one-shot. Turn-level errors (rate limit, error result) propagate.
    private func warmTurn(
        model: String, prompt: String, yield: @escaping (ModelStreamEvent) -> Void
    ) async throws -> Bool {
        guard turn == nil else { return false }  // never clobber an in-flight turn
        if warm == nil || warm?.model != model {
            await teardownWarm()
            do {
                let channel = try await box.execInteractive(Self.warmCommand(model: model))
                let fresh = Warm(channel: channel, model: model)
                warm = fresh
                startPump(fresh)
            } catch {
                return false
            }
        }
        guard let warm else { return false }

        let message = Self.userMessageLine(prompt)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                turn = TurnState(yield: yield, continuation: cont)
                Task {
                    do {
                        try await warm.channel.send(message)
                    } catch {
                        self.failTurn(with: WarmDied())
                    }
                }
            }
            return true
        } catch is WarmDied {
            await teardownWarm()
            return false
        }
    }

    private func startPump(_ warm: Warm) {
        let output = warm.channel.output
        let id = warm.id
        warm.pump = Task { [weak self] in
            do {
                for try await chunk in output {
                    await self?.receive(chunk, warmID: id)
                }
            } catch {}
            await self?.channelEnded(warmID: id)
        }
    }

    private func receive(_ chunk: ExecChunk, warmID: UUID) {
        guard let warm, warm.id == warmID else { return }
        switch chunk {
        case .stderr(let data):
            warm.stderr += String(decoding: data, as: UTF8.self)
        case .stdout(let data):
            for line in warm.lines.feed(data) {
                guard let active = turn else { continue }
                do {
                    if try handle(line: line, stderr: warm.stderr, yield: active.yield) == .done {
                        turn = nil
                        active.continuation.resume()
                    }
                } catch {
                    turn = nil
                    active.continuation.resume(throwing: error)
                }
            }
        }
    }

    private func channelEnded(warmID: UUID) async {
        guard let warm, warm.id == warmID else { return }
        self.warm = nil
        await warm.channel.close()
        failTurn(with: WarmDied())
    }

    private func failTurn(with error: Error) {
        guard let active = turn else { return }
        turn = nil
        active.continuation.resume(throwing: error)
    }

    private func teardownWarm() async {
        guard let warm else { return }
        self.warm = nil
        warm.pump?.cancel()
        await warm.channel.close()
    }

    // MARK: - One-shot fallback

    private func oneShotTurn(
        model: String, prompt: String, yield: (ModelStreamEvent) -> Void
    ) async throws {
        let stream = try await box.exec(Self.oneShotCommand(model: model, prompt: prompt))
        var lines = LineAssembler()
        var stderr = ""
        do {
            for try await chunk in stream {
                switch chunk {
                case .stderr(let data):
                    stderr += String(decoding: data, as: UTF8.self)
                case .stdout(let data):
                    for line in lines.feed(data) {
                        if try handle(line: line, stderr: stderr, yield: yield) == .done {
                            return
                        }
                    }
                }
            }
        } catch let failure as ExecFailure {
            throw Self.mapErrorText(stderr.isEmpty ? "claude exited \(failure.exitCode)" : stderr)
        }
        throw Self.mapErrorText(stderr)
    }

    // MARK: - Event parsing (shared by warm + one-shot)

    private enum LineOutcome {
        case ignored
        case done
    }

    private func handle(
        line: String, stderr: String, yield: (ModelStreamEvent) -> Void
    ) throws -> LineOutcome {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return .ignored }

        switch type {
        case "stream_event":
            if let event = object["event"] as? [String: Any],
                event["type"] as? String == "content_block_delta",
                let delta = event["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String {
                yield(.outputTextDelta(text))
            }
            return .ignored
        case "result":
            let isError = object["is_error"] as? Bool ?? false
            let subtype = object["subtype"] as? String ?? ""
            let text = object["result"] as? String ?? ""
            if isError || subtype != "success" {
                throw Self.mapErrorText([text, subtype, stderr].joined(separator: " "))
            }
            yield(.completed(Self.stripFences(text)))
            return .done
        default:
            return .ignored
        }
    }

    /// Usage/rate-limit exhaustion maps to the quiet rest state (pivot §3);
    /// everything else is a plain failed turn.
    static func mapErrorText(_ text: String) -> ModelClientError {
        let lowered = text.lowercased()
        let restMarkers = [
            "usage limit", "rate limit", "rate_limit", "out of extra usage",
            "credit balance", "limit reached", "resets at",
        ]
        if restMarkers.contains(where: lowered.contains) {
            return .budgetExhausted
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .turnFailed(trimmed.isEmpty ? "no result from claude" : trimmed)
    }

    static func stripFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let newline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            }
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3))
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // MARK: - Invocations (proven on the reference box; login shell required)

    static func warmCommand(model: String) -> String {
        loginShellCommand(
            "claude -p --input-format stream-json --output-format stream-json "
                + "--include-partial-messages --verbose --model \(model) "
                + "--disallowed-tools \"*\"")
    }

    static func oneShotCommand(model: String, prompt: String) -> String {
        loginShellCommand(
            "claude -p --output-format stream-json --include-partial-messages "
                + "--verbose --model \(model) --disallowed-tools \"*\" "
                + shellQuoted(prompt))
    }

    /// One stream-json stdin user message carrying the whole assembled turn.
    static func userMessageLine(_ prompt: String) -> Data {
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": prompt]],
            ],
        ]
        var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        data.append(0x0A)
        return data
    }

    // MARK: - Prompt assembly (app-side, handoff §5)

    /// Instructions + assembled context + the strict turn contract. The CLI
    /// carries no schema enforcement, so the contract is spelled out and
    /// ModelTurnValidation (±2 retries) holds the line app-side.
    static func prompt(for request: TurnRequest) -> String {
        var sections: [String] = [request.instructions]
        let conversation = request.context
            .map { "\($0.role.rawValue): \($0.text)" }
            .joined(separator: "\n\n")
        sections.append("## conversation\n\n" + conversation)
        sections.append(turnContract)
        return sections.joined(separator: "\n\n")
    }

    /// Handoff §5.1, encoded for a schema-free transport.
    static let turnContract = """
        ## turn contract

        Respond with exactly one JSON object and nothing else — no code fences, no prose outside it:
        {"say": string, "patch": PatchOp[] | null}

        PatchOp is one of:
        {"op":"replace_tree","tree":Node}
        {"op":"upsert_node","parentId":string,"node":Node}
        {"op":"update_node","id":string,"fields":{"label"?,"sub"?,"p"?,"actor"?,"move"?,"note"?,"payoff"?,"confidence"?}}
        {"op":"remove_node","id":string}
        {"op":"mark_reached","id":string}
        {"op":"set_unit","payoffUnit":{"kind":"currency"|"utils"|"scale","label":string,"components"?:[{"name":string,"weight":number}]}}
        {"op":"retitle_scenario","title":string}

        Node: {"id":string,"label":string,"sub"?:string,"p":number,"actor":"user"|"counterpart"|"chance","move"?:string,"note"?:string,"payoff"?:number,"confidence"?:"estimated"|"user_set"|"assumed","children"?:Node[]}
        """
}

/// Splits an incoming byte stream into newline-delimited strings.
struct LineAssembler {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }
}
