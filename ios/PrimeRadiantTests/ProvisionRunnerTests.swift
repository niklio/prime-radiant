import XCTest

@testable import PrimeRadiant

/// The provisioning marker grammar (provision.sh header) and the runner that
/// streams the bundle over `sh -s`: stage sequence, token+addr landing, ##fail
/// halting with the sentence verbatim, and chunked/partial-line feeding.
final class ProvisionRunnerTests: XCTestCase {

    // MARK: Parser

    func testParsesTheExactMarkerGrammar() {
        XCTAssertEqual(ProvisionMarkerParser.parse("##stage:reach"), .stage(.reach))
        XCTAssertEqual(ProvisionMarkerParser.parse("##stage:plant"), .stage(.plant))
        XCTAssertEqual(ProvisionMarkerParser.parse("##stage:wake"), .stage(.wake))
        XCTAssertEqual(
            ProvisionMarkerParser.parse("##token:" + String(repeating: "ab", count: 32)),
            .token(String(repeating: "ab", count: 32)))
        XCTAssertEqual(
            ProvisionMarkerParser.parse("##addr:https://radiant.fern-lake.ts.net"),
            .addr("https://radiant.fern-lake.ts.net"))
        XCTAssertEqual(
            ProvisionMarkerParser.parse("##addr:http://100.64.0.9:7717"),
            .addr("http://100.64.0.9:7717"))
        // The one plain sentence travels verbatim — colons inside included.
        XCTAssertEqual(
            ProvisionMarkerParser.parse("##fail:reach:run claude login on the box, then retry."),
            .fail(stage: "reach", message: "run claude login on the box, then retry."))
        XCTAssertNil(ProvisionMarkerParser.parse("random log line"))
        XCTAssertNil(ProvisionMarkerParser.parse("##stage:unknown"))
    }

    func testFeedReassemblesSplitLines() {
        var parser = ProvisionMarkerParser()
        XCTAssertEqual(parser.feed(Data("##stage:re".utf8)), [])
        XCTAssertEqual(parser.feed(Data("ach\n##stage:pl".utf8)), [.stage(.reach)])
        XCTAssertEqual(parser.feed(Data("ant\n".utf8)), [.stage(.plant)])
    }

    // MARK: Runner

    /// Scriptable `sh -s` channel. The runner streams the whole script before
    /// reading, so the scripted stdout is pre-buffered in the output stream
    /// (AsyncThrowingStream buffers) — the read loop then drains it, exactly
    /// like `sh` reaching `exit 0` after consuming stdin.
    private final class ProvisionBox: SSHBox, @unchecked Sendable {
        let lines: [String]
        private(set) var receivedScript = Data()
        private let lock = NSLock()

        init(lines: [String]) {
            self.lines = lines
        }

        var isConnected: Bool { true }

        func connect(address: String, auth: BoxAuth, pinnedHostKey: Data?) async throws -> Data {
            Data()
        }

        func disconnect() async {}

        func exec(_ command: String) async throws -> AsyncThrowingStream<ExecChunk, Error> {
            let (stream, continuation) = AsyncThrowingStream<ExecChunk, Error>.makeStream()
            continuation.finish()
            return stream
        }

        private func record(_ data: Data) {
            lock.lock()
            receivedScript.append(data)
            lock.unlock()
        }

        func execInteractive(_ command: String) async throws -> ExecChannel {
            let (output, continuation) = AsyncThrowingStream<ExecChunk, Error>.makeStream()
            for line in lines {
                continuation.yield(.stdout(Data((line + "\n").utf8)))
            }
            continuation.finish()
            return ExecChannel(
                output: output,
                send: { [weak self] data in
                    self?.record(data)
                },
                close: {})
        }

        func sftpRead(path: String) async throws -> Data { throw SSHBoxError.channelFailed }
        func sftpWrite(path: String, data: Data) async throws {}
        func sftpList(directory: String) async throws -> [String] { [] }
        func sftpMkdir(path: String) async throws {}
        func sftpRename(from: String, to: String) async throws {}
        func sftpRemove(path: String) async throws {}
    }

    func testRunnerStreamsScriptAndCollectsTokenAndAddr() async throws {
        let token = String(repeating: "0f", count: 32)
        let box = ProvisionBox(lines: [
            "##stage:reach", "##stage:plant", "##stage:wake",
            "##token:\(token)", "##addr:http://100.64.0.9:7717",
        ])
        let runner = ProvisionRunner(box: box)
        let script = Data(repeating: 0x23, count: 100_000)  // 100KB of '#'

        let events = EventCollector()
        let outcome = try await runner.run(script: script) { events.append($0) }

        XCTAssertEqual(outcome, ProvisionOutcome(token: token, addr: "http://100.64.0.9:7717"))
        XCTAssertEqual(box.receivedScript.count, script.count, "the whole bundle must stream")
        XCTAssertEqual(
            Array(events.snapshot().prefix(3)),
            [.stage(.reach), .stage(.plant), .stage(.wake)])
    }

    func testRunnerThrowsOnFailMarkerWithSentenceVerbatim() async {
        let box = ProvisionBox(lines: [
            "##stage:reach",
            "##fail:reach:install node 20 or newer on the box, then retry.",
        ])
        let runner = ProvisionRunner(box: box)

        do {
            _ = try await runner.run(script: Data("x\n".utf8)) { _ in }
            XCTFail("expected ProvisionFailure")
        } catch let failure as ProvisionFailure {
            XCTAssertEqual(failure.stage, "reach")
            XCTAssertEqual(failure.message, "install node 20 or newer on the box, then retry.")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRunnerFailsWhenChannelEndsWithoutToken() async {
        let box = ProvisionBox(lines: ["##stage:reach", "##stage:plant"])
        let runner = ProvisionRunner(box: box)
        do {
            _ = try await runner.run(script: Data("x\n".utf8)) { _ in }
            XCTFail("expected ProvisionFailure")
        } catch let failure as ProvisionFailure {
            XCTAssertEqual(failure.stage, "wake")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The bundled artifact ships in the app bundle and carries the payload
    /// (self-contained provisioning — no network beyond the SSH channel).
    func testProvisionBundleIsBundledWithPayload() throws {
        let script = try XCTUnwrap(
            ProvisionRunner.bundledScript(),
            "server/dist/provision-bundle.sh must be bundled as a resource")
        XCTAssertGreaterThan(script.count, 100_000, "bundle should embed the gateway payload")
        let head = String(decoding: script.prefix(4096), as: UTF8.self)
        XCTAssertTrue(head.contains("##stage") || head.contains("#!/bin/sh"))
    }
}

/// Thread-safe event sink for @Sendable callbacks in tests.
private final class EventCollector: @unchecked Sendable {
    private var events: [ProvisionEvent] = []
    private let lock = NSLock()

    func append(_ event: ProvisionEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [ProvisionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
