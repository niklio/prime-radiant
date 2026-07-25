import PrimeRadiantCore
import XCTest

@testable import PrimeRadiant

/// The gateway chat path (server/README chat contract) with a fake gateway —
/// no live turns, ever: SSE parsing, say-delta streaming, the validated turn
/// event with the client-side second check, budget_resting mapping, and the
/// routed fallback to SSH on transport failure.
final class GatewayChatTests: XCTestCase {

    // MARK: SSE parser

    func testSSEParserSplitsEventsAndIgnoresKeepalives() {
        var parser = SSEParser()
        var events = parser.feed(Data("event: say\ndata: {\"text\":\"he\"}\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "say", data: "{\"text\":\"he\"}")])

        // Keepalive comments and chunk-split frames.
        events = parser.feed(Data(": ping\nevent: turn\ndata: {\"say\":".utf8))
        XCTAssertEqual(events, [])
        events = parser.feed(Data("\"done\",\"patch\":null}\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "turn", data: "{\"say\":\"done\",\"patch\":null}")])
    }

    func testSSEParserHandlesCRLF() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: done\r\ndata: {}\r\n\r\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "done", data: "{}")])
    }

    // MARK: Fake gateway

    private struct FakeGateway: GatewayAPI {
        var events: [SSEEvent] = []
        var chatThrows = false

        func health(base: URL) async -> GatewayHealth? { nil }

        func pair(base: URL, code: String) async throws -> String { "t" }

        func chat(base: URL, token: String, body: Data) async throws
            -> AsyncThrowingStream<SSEEvent, Error>
        {
            if chatThrows { throw GatewayError.unreachable }
            let (stream, continuation) = AsyncThrowingStream<SSEEvent, Error>.makeStream()
            for event in events { continuation.yield(event) }
            continuation.finish()
            return stream
        }

        func request(base: URL, token: String, method: String, path: String, body: Data?)
            async throws -> (status: Int, data: Data)
        {
            (404, Data())
        }
    }

    private func sampleScenario() -> Scenario {
        Scenario(
            id: "01J0PRTESTSCENARI000000001",
            title: "sample",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            payoffUnit: PayoffUnit(kind: .currency, label: "USD"),
            status: .modeling,
            tree: Node(id: "01J0PRTESTR00T000000000001", label: "root", p: 1, actor: .user))
    }

    private func engine(_ gateway: FakeGateway) -> GatewayTurnEngine {
        GatewayTurnEngine(
            gateway: gateway,
            base: URL(string: "http://100.64.0.9:7717")!,
            token: "token",
            config: .fallback)
    }

    // MARK: Turn flow

    func testSayDeltasStreamAndTurnEventLands() async throws {
        let gateway = FakeGateway(events: [
            SSEEvent(event: "say", data: #"{"text":"the "}"#),
            SSEEvent(event: "say", data: #"{"text":"futures shift"}"#),
            SSEEvent(event: "turn", data: #"{"say":"the futures shift","patch":null}"#),
            SSEEvent(event: "done", data: "{}"),
        ])

        let deltas = DeltaCollector()
        let turn = try await engine(gateway).runTurn(
            scenario: sampleScenario(), userText: "hello", focusedNodeId: nil,
            useRestructureModel: false, onSayDelta: { deltas.append($0) })

        XCTAssertEqual(turn.say, "the futures shift")
        XCTAssertNil(turn.patch)
        XCTAssertEqual(deltas.joined(), "the futures shift")
    }

    /// The server validated the turn already; the client's dry-run stays as a
    /// second check — an impossible patch is still rejected.
    func testClientSecondCheckRejectsImpossiblePatch() async {
        let gateway = FakeGateway(events: [
            SSEEvent(
                event: "turn",
                data: #"{"say":"ok","patch":[{"op":"remove_node","id":"missing"}]}"#),
            SSEEvent(event: "done", data: "{}"),
        ])

        do {
            _ = try await engine(gateway).runTurn(
                scenario: sampleScenario(), userText: "x", focusedNodeId: nil,
                useRestructureModel: false, onSayDelta: { _ in })
            XCTFail("expected invalidAfterRetries")
        } catch let error as ModelClientError {
            guard case .invalidAfterRetries = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testBudgetRestingMapsToBudgetExhausted() async {
        let gateway = FakeGateway(events: [
            SSEEvent(event: "error", data: #"{"error":"budget_resting"}"#),
            SSEEvent(event: "done", data: "{}"),
        ])

        do {
            _ = try await engine(gateway).runTurn(
                scenario: sampleScenario(), userText: "x", focusedNodeId: nil,
                useRestructureModel: false, onSayDelta: { _ in })
            XCTFail("expected budgetExhausted")
        } catch let error as ModelClientError {
            XCTAssertEqual(error, .budgetExhausted)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Routed fallback

    /// Gateway transport failure → the SSH engine runs the turn, quietly, and
    /// the ladder is told.
    func testRoutedEngineFallsBackToSSHOnTransportFailure() async throws {
        let gateway = FakeGateway(chatThrows: true)
        let scenario = sampleScenario()

        // SSH engine backed by the FakeBox warm channel.
        let box = FakeBox()
        box.acceptsNoneAuth = true
        box.turnScripts = [
            [
                StreamJSON.textDelta(#"{"say":"from ssh","patch":null}"#),
                StreamJSON.result(#"{"say":"from ssh","patch":null}"#),
            ]
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })
        let sshEngine = ModelSession(backend: backend, config: .fallback)

        let failures = DeltaCollector()
        let routed = RoutedTurnEngine(
            transport: { .gateway },
            gatewayEngine: {
                GatewayTurnEngine(
                    gateway: gateway,
                    base: URL(string: "http://100.64.0.9:7717")!,
                    token: "token",
                    config: .fallback)
            },
            sshEngine: sshEngine,
            onGatewayFailure: { failures.append("noted") })

        let turn = try await routed.runTurn(
            scenario: scenario, userText: "x", focusedNodeId: nil,
            useRestructureModel: false, onSayDelta: { _ in })

        XCTAssertEqual(turn.say, "from ssh")
        XCTAssertEqual(failures.joined(), "noted", "the ladder must learn of the failure")
    }

    /// SSH transport selected → the gateway is never touched.
    func testRoutedEngineUsesSSHWhenLadderSaysSSH() async throws {
        let box = FakeBox()
        box.turnScripts = [
            [StreamJSON.result(#"{"say":"ssh turn","patch":null}"#)]
        ]
        let backend = ClaudeSSHBackend(box: box, ensureConnected: { true })
        let routed = RoutedTurnEngine(
            transport: { .ssh },
            gatewayEngine: {
                XCTFail("gateway engine must not be consulted on the SSH path")
                return nil
            },
            sshEngine: ModelSession(backend: backend, config: .fallback),
            onGatewayFailure: {})

        let turn = try await routed.runTurn(
            scenario: sampleScenario(), userText: "x", focusedNodeId: nil,
            useRestructureModel: false, onSayDelta: { _ in })
        XCTAssertEqual(turn.say, "ssh turn")
    }
}

/// Thread-safe string sink for @Sendable delta callbacks.
private final class DeltaCollector: @unchecked Sendable {
    private var parts: [String] = []
    private let lock = NSLock()

    func append(_ part: String) {
        lock.lock()
        parts.append(part)
        lock.unlock()
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return parts.joined()
    }
}
