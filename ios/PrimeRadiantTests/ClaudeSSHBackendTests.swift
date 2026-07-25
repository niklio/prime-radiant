import PrimeRadiantCore
import XCTest

@testable import PrimeRadiant

/// ClaudeSSHBackend against the FakeBox: warm-session happy path, delta
/// filtering, budget-rest mapping, warm-death fallback to one-shot, and the
/// ModelSession invalid-JSON retry loop on top of it.
final class ClaudeSSHBackendTests: XCTestCase {

    private let turnJSON = #"{"say":"hello","patch":null}"#

    private func makeRequest(model: String = "sonnet") -> TurnRequest {
        TurnRequest(
            model: model,
            instructions: "instructions",
            context: [.init(role: .user, text: "hi")])
    }

    private func collect(
        _ backend: ClaudeSSHBackend, _ request: TurnRequest
    ) async throws -> (deltas: [String], completed: String?) {
        var deltas: [String] = []
        var completed: String?
        for try await event in try await backend.stream(request) {
            switch event {
            case .outputTextDelta(let delta): deltas.append(delta)
            case .completed(let full): completed = full
            }
        }
        return (deltas, completed)
    }

    // MARK: Warm session

    func testWarmTurnStreamsDeltasAndCompletes() async throws {
        let box = FakeBox()
        box.turnScripts = [
            [
                StreamJSON.textDelta(#"{"say":"hel"#),
                StreamJSON.textDelta(#"lo","patch":null}"#),
                StreamJSON.result(turnJSON),
            ]
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })

        let output = try await collect(backend, makeRequest())
        XCTAssertEqual(output.deltas, [#"{"say":"hel"#, #"lo","patch":null}"#])
        XCTAssertEqual(output.completed, turnJSON)

        // The warm channel was spawned with the proven invocation: login shell,
        // stream-json both ways, partial messages, tools disabled, alias model.
        let spawn = box.log.first { $0.hasPrefix("spawn") }
        XCTAssertNotNil(spawn)
        for fragment in [
            "zsh -lc", "--input-format stream-json", "--output-format stream-json",
            "--include-partial-messages", "--model sonnet", "--disallowed-tools \"*\"",
        ] {
            XCTAssertTrue(spawn!.contains(fragment), "spawn missing \(fragment): \(spawn!)")
        }
    }

    func testWarmChannelIsReusedAcrossTurns() async throws {
        let box = FakeBox()
        box.turnScripts = [
            [StreamJSON.result(turnJSON)],
            [StreamJSON.result(turnJSON)],
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })

        _ = try await collect(backend, makeRequest())
        _ = try await collect(backend, makeRequest())

        XCTAssertEqual(box.log.filter { $0.hasPrefix("spawn") }.count, 1)
        XCTAssertEqual(box.log.filter { $0.hasPrefix("stdin") }.count, 2)
    }

    func testThinkingDeltasAreFiltered() async throws {
        let box = FakeBox()
        box.turnScripts = [
            [
                StreamJSON.thinkingDelta("pondering"),
                StreamJSON.textDelta(turnJSON),
                StreamJSON.result(turnJSON),
            ]
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })

        let output = try await collect(backend, makeRequest())
        XCTAssertEqual(output.deltas, [turnJSON])
    }

    func testCodeFencesAreStrippedFromResult() async throws {
        let box = FakeBox()
        box.turnScripts = [
            [StreamJSON.result("```json\n\(turnJSON)\n```")]
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })

        let output = try await collect(backend, makeRequest())
        XCTAssertEqual(output.completed, turnJSON)
    }

    // MARK: Quiet-state mapping

    func testUsageLimitResultMapsToBudgetExhausted() async {
        let box = FakeBox()
        box.turnScripts = [
            [StreamJSON.result("You've reached your usage limit · resets at 5pm", isError: true)]
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })

        do {
            _ = try await collect(backend, makeRequest())
            XCTFail("expected budgetExhausted")
        } catch {
            XCTAssertEqual(error as? ModelClientError, .budgetExhausted)
        }
    }

    func testUnreachableBoxMapsToBoxUnreachable() async {
        let box = FakeBox()
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { false })

        do {
            _ = try await backend.stream(makeRequest())
            XCTFail("expected boxUnreachable")
        } catch {
            XCTAssertEqual(error as? ModelClientError, .boxUnreachable)
        }
    }

    // MARK: One-shot fallback

    func testSpawnFailureFallsBackToOneShot() async throws {
        let box = FakeBox()
        box.interactiveSpawnFails = true
        box.execHandlers = [
            (
                contains: "claude -p",
                stdout: [
                    StreamJSON.textDelta(turnJSON),
                    StreamJSON.result(turnJSON),
                ].joined(separator: "\n") + "\n",
                exitCode: 0
            )
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })

        let output = try await collect(backend, makeRequest())
        XCTAssertEqual(output.completed, turnJSON)

        let oneShot = box.log.first { $0.hasPrefix("exec") && $0.contains("claude -p") }
        XCTAssertNotNil(oneShot, "one-shot fallback never ran")
        XCTAssertTrue(oneShot!.contains("--output-format stream-json"))
        XCTAssertTrue(oneShot!.contains("instructions"), "prompt not passed as argv")
    }

    func testWarmDeathMidTurnFallsBackToOneShot() async throws {
        let box = FakeBox()
        box.turnScripts = [nil]  // channel drops on first send
        box.execHandlers = [
            (
                contains: "claude -p",
                stdout: StreamJSON.result(turnJSON) + "\n",
                exitCode: 0
            )
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })

        let output = try await collect(backend, makeRequest())
        XCTAssertEqual(output.completed, turnJSON)
        XCTAssertTrue(box.log.contains { $0.hasPrefix("exec") && $0.contains("claude -p") })
    }

    // MARK: ModelSession retry loop on top of the backend

    @MainActor
    func testInvalidJSONTurnRetriesWithValidatorFeedback() async throws {
        let box = FakeBox()
        box.turnScripts = [
            [StreamJSON.result("this is not the contract")],
            [StreamJSON.result(#"{"say":"fixed","patch":null}"#)],
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })
        let session = ModelSession(backend: backend, config: .fallback)

        let turn = try await session.runTurn(
            scenario: Self.scenario, userText: "hello", focusedNodeId: nil,
            onSayDelta: { _ in })
        XCTAssertEqual(turn.say, "fixed")

        // The retry carried the validator error in-context (§5.1).
        let sends = box.log.filter { $0.hasPrefix("stdin") }
        XCTAssertEqual(sends.count, 2)
        XCTAssertTrue(sends[1].contains("failed validation"))
    }

    @MainActor
    func testBudgetExhaustionPropagatesThroughModelSession() async {
        let box = FakeBox()
        box.turnScripts = [
            [StreamJSON.result("5-hour limit reached", isError: true)]
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })
        let session = ModelSession(backend: backend, config: .fallback)

        do {
            _ = try await session.runTurn(
                scenario: Self.scenario, userText: "hello", focusedNodeId: nil,
                onSayDelta: { _ in })
            XCTFail("expected budgetExhausted")
        } catch {
            XCTAssertEqual(error as? ModelClientError, .budgetExhausted)
        }
    }

    // MARK: Fixtures

    private static let scenario = Scenario(
        id: "01J0TESTSCENARI0000000001",
        title: "test",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        payoffUnit: PayoffUnit(kind: .currency, label: "USD"),
        status: .modeling,
        tree: Node(id: "01J0TESTR00T0000000000001", label: "root", p: 1, actor: .user))
}
