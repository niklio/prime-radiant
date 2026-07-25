import XCTest

@testable import PrimeRadiant

/// The staged pairing flow (ux-update §1) against fakes: the probe ladder
/// (gateway → Tailscale SSH → plain sshd → unreachable), the code fallback,
/// the full provision-to-paired path, and the wrong-code shake.
@MainActor
final class PairingControllerTests: XCTestCase {

    private final class ScriptedGateway: GatewayAPI, @unchecked Sendable {
        var healthByBase: [String: GatewayHealth] = [:]
        var pairResult: Result<String, GatewayError> = .failure(.pairingUnavailable)

        func health(base: URL) async -> GatewayHealth? {
            healthByBase[base.absoluteString]
        }

        func pair(base: URL, code: String) async throws -> String {
            switch pairResult {
            case .success(let token): return token
            case .failure(let error): throw error
            }
        }

        func chat(base: URL, token: String, body: Data) async throws
            -> AsyncThrowingStream<SSEEvent, Error>
        {
            let (stream, continuation) = AsyncThrowingStream<SSEEvent, Error>.makeStream()
            continuation.finish()
            return stream
        }

        func request(base: URL, token: String, method: String, path: String, body: Data?)
            async throws -> (status: Int, data: Data)
        {
            (404, Data())
        }
    }

    private func sshReadyBox() -> FakeBox {
        let box = FakeBox()
        box.execHandlers = [
            (contains: "claude --version", stdout: "2.1.178 (Claude Code)\n", exitCode: 0),
            (contains: "ANTHROPIC_API_KEY", stdout: "0\n", exitCode: 1),
        ]
        return box
    }

    private func makeController(
        box: FakeBox, gateway: ScriptedGateway, script: Data = Data("#!/bin/sh\n".utf8)
    ) -> (PairingController, adopted: () -> PairedBox?) {
        let adopted = AdoptedBox()
        let controller = PairingController(
            box: box,
            gateway: gateway,
            provisionScript: { script },
            makeKey: { Data(repeating: 7, count: 32) },
            onPaired: { adopted.record = $0 })
        return (controller, { adopted.record })
    }

    private final class AdoptedBox {
        var record: PairedBox?
    }

    private func waitFor(
        _ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Probe ladder

    func testUnreachableIsAnInlineStateNotAScreen() async {
        let box = sshReadyBox()
        box.unreachable = true
        let (controller, _) = makeController(box: box, gateway: ScriptedGateway())

        controller.address = "radiant.fern-lake.ts.net"
        controller.submitAddress()

        let landed = await waitFor(controller.unreachable)
        XCTAssertTrue(landed, "unreachable never set")
        XCTAssertEqual(controller.stage, .address, "1b2 is the same screen's failure state")

        // Editing the field IS the retry: the line fades as typing resumes.
        controller.address = "radiant.fern-lake.ts.net "
        controller.addressEdited()
        XCTAssertFalse(controller.unreachable)
    }

    func testUnpairedGatewayGoesToCodeFallback() async {
        let gateway = ScriptedGateway()
        gateway.healthByBase["http://box:7717"] = GatewayHealth(
            ok: true, version: "0.1.0", paired: false, agentReady: true, budget: "ok")
        let (controller, _) = makeController(box: sshReadyBox(), gateway: gateway)

        controller.address = "box"
        controller.submitAddress()

        let landed = await waitFor(controller.stage == .code)
        XCTAssertTrue(landed, "hand-installed unpaired gateway → 1c code screen")
    }

    func testPlainSshdChallengesForCredentials() async {
        let box = sshReadyBox()
        box.passwords = ["nik": "hunter2"]  // native sshd; .none auth fails
        let (controller, _) = makeController(box: box, gateway: ScriptedGateway())

        controller.address = "100.64.0.9"
        controller.submitAddress()

        let landed = await waitFor(controller.stage == .credentials)
        XCTAssertTrue(landed, "plain sshd → 1b3 credentials")
    }

    // MARK: Provision path (Tailscale SSH: no credentials at all)

    func testTailscalePathProvisionsToPaired() async {
        let box = sshReadyBox()
        box.acceptsNoneAuth = true
        let token = String(repeating: "ab", count: 32)
        // The FakeBox warm channel pops one script per stdin send; a >32KB
        // payload spans two sends, so the second drains the queue and EOFs —
        // exactly the runner's send-then-read shape.
        box.turnScripts = [
            [
                "##stage:reach", "##stage:plant", "##stage:wake",
                "##token:\(token)", "##addr:https://radiant.fern-lake.ts.net",
            ]
        ]
        let (controller, adopted) = makeController(
            box: box, gateway: ScriptedGateway(),
            script: Data(repeating: 0x23, count: 40_000))

        controller.address = "radiant.fern-lake.ts.net"
        controller.submitAddress()

        let landed = await waitFor(controller.stage == .paired)
        XCTAssertTrue(landed, "tailscale probe → provisioning → paired; got \(controller.stage)")
        XCTAssertEqual(controller.reach, .done)
        XCTAssertEqual(controller.plant, .done)
        XCTAssertEqual(controller.wake, .done)
        XCTAssertEqual(controller.pairedAddress, "radiant.fern-lake.ts.net")

        // The record lands only after the 1d frame plays.
        XCTAssertNil(adopted())
        controller.completePairing()
        XCTAssertEqual(adopted()?.deviceToken, token)
        XCTAssertEqual(adopted()?.gatewayAddress, "https://radiant.fern-lake.ts.net")
        XCTAssertEqual(adopted()?.flavor, .tailscale)
    }

    func testProvisionFailureHaltsOnTheLineWithSentenceVerbatim() async {
        let box = sshReadyBox()
        box.acceptsNoneAuth = true
        box.turnScripts = [
            [
                "##stage:reach",
                "##fail:reach:run claude login on the box, then retry.",
            ]
        ]
        let (controller, _) = makeController(
            box: box, gateway: ScriptedGateway(),
            script: Data(repeating: 0x23, count: 40_000))

        controller.address = "box"
        controller.submitAddress()

        let halted = await waitFor(
            controller.reach == .failed("run claude login on the box, then retry."))
        XCTAssertTrue(halted, "##fail must halt the line with the sentence verbatim")
        XCTAssertEqual(controller.stage, .provisioning, "halt stays on 1c2; retry resumes")
    }

    // MARK: Code fallback

    private func controllerOnCodeScreen(
        gateway: ScriptedGateway
    ) async -> (PairingController, () -> PairedBox?) {
        gateway.healthByBase["http://box:7717"] = GatewayHealth(
            ok: true, version: "0.1.0", paired: false, agentReady: true, budget: "ok")
        let (controller, adopted) = makeController(box: sshReadyBox(), gateway: gateway)
        controller.address = "box"
        controller.submitAddress()
        _ = await waitFor(controller.stage == .code)
        return (controller, adopted)
    }

    func testSixthCharacterAutoSubmitsAndPairs() async {
        let gateway = ScriptedGateway()
        gateway.pairResult = .success("token-abc")
        let (controller, adopted) = await controllerOnCodeScreen(gateway: gateway)

        controller.code = "7k41m9"
        controller.codeEdited()  // uppercases + auto-submits at six

        let landed = await waitFor(controller.stage == .paired)
        XCTAssertTrue(landed)
        controller.completePairing()
        XCTAssertEqual(adopted()?.deviceToken, "token-abc")
        XCTAssertEqual(adopted()?.flavor, .gateway)
        XCTAssertEqual(adopted()?.gatewayAddress, "http://box:7717")
    }

    func testWrongCodeShakesAndClears() async {
        let gateway = ScriptedGateway()
        gateway.pairResult = .failure(.invalidCode)
        let (controller, _) = await controllerOnCodeScreen(gateway: gateway)

        controller.code = "WRONG1"
        controller.codeEdited()

        let rejected = await waitFor(controller.codeRejections == 1)
        XCTAssertTrue(rejected)
        XCTAssertEqual(controller.code, "", "wrong code clears the cells")
        XCTAssertEqual(controller.stage, .code)
    }
}
