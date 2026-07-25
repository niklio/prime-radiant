import PrimeRadiantCore
import XCTest

@testable import PrimeRadiant

/// The quiet states (pivot §3): box unreachable → read-only with "the radiant
/// is beyond reach"; usage window exhausted → "the radiant rests until the
/// cycle renews". Composer and marking disable quietly; no dialogs.
@MainActor
final class ReadOnlyGatingTests: XCTestCase {

    private func makeScenario() -> Scenario {
        let child = Node(
            id: "01J0GATECHILD000000000001", label: "child", p: 1, actor: .counterpart,
            payoff: .scalar(10))
        return Scenario(
            id: "01J0GATESCENARI0000000001",
            title: "test",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            payoffUnit: PayoffUnit(kind: .currency, label: "USD"),
            status: .modeling,
            tree: Node(
                id: "01J0GATER00T0000000000001", label: "root", p: 1, actor: .user,
                children: [child]))
    }

    private func makeStore(
        backend: (any ModelBackend)? = nil
    ) -> ScenarioStore {
        let session = backend.map { ModelSession(backend: $0, config: .fallback) }
        return ScenarioStore(
            scenario: makeScenario(),
            modelSession: session,
            radiant: RadiantScene(reduceMotion: true),
            onPersist: { _ in })
    }

    private func waitUntil(
        timeout: TimeInterval = 3, _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Read-only (box beyond reach)

    func testReadOnlyShowsStatusLineInComposerSlot() {
        let store = makeStore()
        store.isReadOnly = true
        XCTAssertEqual(store.composerStatusLine, "the radiant is beyond reach")
    }

    func testReadOnlySendIsQuietlyIgnored() async {
        let backend = ScriptedBackend(events: [.completed(#"{"say":"hi","patch":null}"#)])
        let store = makeStore(backend: backend)
        store.isReadOnly = true

        store.send(text: "hello")
        await waitUntil { !store.isStreaming }

        XCTAssertTrue(store.scenario.transcript.isEmpty, "read-only send appended a message")
        XCTAssertNil(store.lastError, "read-only send raised an error — must stay quiet")
    }

    func testReadOnlyMarkingIsQuietlyIgnored() {
        let store = makeStore()
        store.isReadOnly = true

        store.completeHold(id: "01J0GATECHILD000000000001", intent: .mark)

        XCTAssertTrue(store.scenario.realizedPath.isEmpty)
        XCTAssertNil(store.lastError)
    }

    func testWritableStoreHasNoStatusLine() {
        let store = makeStore()
        XCTAssertNil(store.composerStatusLine)
    }

    // MARK: Budget rest

    func testBudgetExhaustionEntersRestState() async {
        let backend = ScriptedBackend(failure: .budgetExhausted)
        let store = makeStore(backend: backend)

        store.send(text: "hello")
        await waitUntil { store.composerStatusLine != nil }

        XCTAssertEqual(store.composerStatusLine, "the radiant rests until the cycle renews")
        XCTAssertNil(store.lastError, "budget rest must be quiet — no toast, no dialog")

        // Resting composer swallows further sends.
        let turns = store.scenario.transcript.count
        store.send(text: "again")
        XCTAssertEqual(store.scenario.transcript.count, turns)
    }

    func testUnreachableTurnFlipsReadOnly() async {
        let backend = ScriptedBackend(failure: .boxUnreachable)
        let store = makeStore(backend: backend)

        store.send(text: "hello")
        await waitUntil { store.composerStatusLine != nil }

        XCTAssertEqual(store.composerStatusLine, "the radiant is beyond reach")
        XCTAssertNil(store.lastError)
    }

    func testOtherFailuresStillToastInVoice() async {
        let backend = ScriptedBackend(failure: .turnFailed("boom"))
        let store = makeStore(backend: backend)

        store.send(text: "hello")
        await waitUntil { store.lastError != nil }

        XCTAssertEqual(store.lastError, "the radiant lost the thread · try again")
        XCTAssertNil(store.composerStatusLine)
    }
}

/// Minimal scripted ModelBackend for store-level tests.
private struct ScriptedBackend: ModelBackend {
    var events: [ModelStreamEvent] = []
    var failure: ModelClientError?

    func stream(_ request: TurnRequest) async throws -> AsyncThrowingStream<ModelStreamEvent, Error> {
        if let failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<ModelStreamEvent, Error>.makeStream()
        for event in events { continuation.yield(event) }
        continuation.finish()
        return stream
    }
}
