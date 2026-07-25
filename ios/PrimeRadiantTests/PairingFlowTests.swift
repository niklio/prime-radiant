import XCTest

@testable import PrimeRadiant

/// The pairing state machine (pivot v3) against the FakeBox: both auth
/// flavors, the key-installation call sequence, host-key mismatch abort, and
/// the ANTHROPIC_API_KEY warning.
final class PairingFlowTests: XCTestCase {

    private static let fixedKey = Data(repeating: 7, count: 32)

    private func makeBox() -> FakeBox {
        let box = FakeBox()
        box.execHandlers = [
            (contains: "claude --version", stdout: "2.1.178 (Claude Code)\n", exitCode: 0),
            // grep -c exits 1 on zero matches; the count is still the answer.
            (contains: "ANTHROPIC_API_KEY", stdout: "0\n", exitCode: 1),
        ]
        return box
    }

    private func flow(_ box: FakeBox) -> PairingFlow {
        PairingFlow(box: box, makeKey: { Self.fixedKey })
    }

    // MARK: Tailscale flavor

    func testTailscaleFlavorPairsWithNoCredentials() async {
        let box = makeBox()
        box.acceptsNoneAuth = true

        let outcome = await flow(box).pair(address: "radiant.tail.ts.net", username: "nik", password: nil)

        guard case .paired(let record) = outcome else {
            return XCTFail("expected paired, got \(outcome)")
        }
        XCTAssertEqual(record.flavor, .tailscale)
        XCTAssertEqual(record.address, "radiant.tail.ts.net")
        XCTAssertEqual(record.hostKeyPin, Data("hostkey-A".utf8))
        XCTAssertNil(record.privateKeyRaw)
        XCTAssertFalse(record.apiKeyWarning)
        // No key installation on the tailscale path.
        XCTAssertFalse(box.log.contains { $0.contains("authorized_keys") })
        // Health checks ran through a login shell.
        XCTAssertTrue(box.log.contains { $0.contains("zsh -lc") && $0.contains("claude --version") })
    }

    // MARK: Password flavor + key installation

    func testPasswordFlavorChallengesThenInstallsKey() async {
        let box = makeBox()
        box.passwords = ["nik": "hunter2"]

        // First attempt carries no password: the box challenges.
        let first = await flow(box).pair(address: "100.64.0.9", username: "nik", password: nil)
        XCTAssertEqual(first, .needsPassword)

        // Second attempt: password once → install app key → reconnect by key.
        let second = await flow(box).pair(address: "100.64.0.9", username: "nik", password: "hunter2")
        guard case .paired(let record) = second else {
            return XCTFail("expected paired, got \(second)")
        }
        XCTAssertEqual(record.flavor, .key)
        XCTAssertEqual(record.privateKeyRaw, Self.fixedKey)
        XCTAssertTrue(box.keyInstalled)

        // Exact call sequence: none-auth probe → password connect → key install
        // → reconnect with the key (password never used again).
        let calls = box.log.filter {
            $0.hasPrefix("connect") || $0.contains("authorized_keys")
        }
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(calls[0], "connect none(nik)")  // first attempt
        XCTAssertEqual(calls[1], "connect none(nik)")  // second attempt probes again
        XCTAssertEqual(calls[2], "connect password(nik)")
        XCTAssertTrue(calls[3].contains("authorized_keys"), "expected key install, got \(calls[3])")
        XCTAssertEqual(calls[4], "connect key(nik)")
    }

    func testInstalledKeyLineIsWellFormed() {
        let line = PairingFlow.authorizedKeyLine(privateKeyRaw: Self.fixedKey)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(line!.hasSuffix(" prime-radiant"))
        let blob = Data(base64Encoded: String(line!.split(separator: " ")[1]))
        // 4 + "ssh-ed25519" + 4 + 32-byte key.
        XCTAssertEqual(blob?.count, 4 + 11 + 4 + 32)
    }

    func testWrongPasswordFailsInVoice() async {
        let box = makeBox()
        box.passwords = ["nik": "hunter2"]

        let outcome = await flow(box).pair(address: "100.64.0.9", username: "nik", password: "wrong")
        XCTAssertEqual(outcome, .failed("the box did not accept that password"))
    }

    // MARK: Host-key pinning

    func testHostKeyMismatchAbortsPairing() async {
        let box = makeBox()
        box.passwords = ["nik": "hunter2"]
        // none-probe and password connect present A; the key reconnect presents
        // B against the freshly pinned A → hard fail (pivot v3).
        box.hostKeys = [
            Data("hostkey-A".utf8), Data("hostkey-A".utf8), Data("hostkey-B".utf8),
        ]

        let outcome = await flow(box).pair(address: "100.64.0.9", username: "nik", password: "hunter2")
        XCTAssertEqual(outcome, .failed("another machine answers to this name · pairing refused"))
    }

    // MARK: Health checks

    func testApiKeyWarningSurfacesAndAllowsPairing() async {
        let box = makeBox()
        box.acceptsNoneAuth = true
        box.execHandlers = [
            (contains: "claude --version", stdout: "2.1.178 (Claude Code)\n", exitCode: 0),
            (contains: "ANTHROPIC_API_KEY", stdout: "1\n", exitCode: 0),
        ]

        let outcome = await flow(box).pair(address: "box", username: "nik", password: nil)
        guard case .paired(let record) = outcome else {
            return XCTFail("expected paired-with-warning, got \(outcome)")
        }
        XCTAssertTrue(record.apiKeyWarning)
    }

    func testMissingClaudeFailsInVoice() async {
        let box = makeBox()
        box.acceptsNoneAuth = true
        box.execHandlers = [
            (contains: "claude --version", stdout: "", exitCode: 127)
        ]

        let outcome = await flow(box).pair(address: "box", username: "nik", password: nil)
        XCTAssertEqual(outcome, .failed("claude is not answering on the box"))
    }

    func testUnreachableBoxFailsInVoice() async {
        let box = makeBox()
        box.unreachable = true

        let outcome = await flow(box).pair(address: "box", username: "nik", password: nil)
        XCTAssertEqual(outcome, .failed("the box is beyond reach"))
    }
}
