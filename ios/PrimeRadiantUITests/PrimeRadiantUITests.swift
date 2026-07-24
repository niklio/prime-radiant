import XCTest

/// M1 canvas happy-path XCUITests (handoff §8), driven against the bundled
/// job-offer sample scenario (`-PRDebugSample`) with the `-PRUITestHooks`
/// accessibility overlay exposing per-node elements (`node.<ulid>`) and a
/// `canvas.state` element ("selected=<id|none> reached=<n>"). Taps and holds on
/// the hook elements pass through to the real SCNView gesture + picking path —
/// nothing here short-circuits the production interaction code.
///
/// Still to come with later milestones: create → converse → patch flows (M2),
/// resolve flow + constellation management (M3), voice path (M4).
final class PrimeRadiantUITests: XCTestCase {

    private var app: XCUIApplication!

    // Node ids from shared/samples/job-offer.json (generic sample content, §10).
    private let rootId = "01J0PRSAMPR00T000000000001"
    /// "counter at 185k" — non-terminal, depth 1, has a `move` and payoffs below.
    private let counterId = "01J0PRSAMPC0NTR00000000003"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-PRDebugSample", "-PRUITestHooks"]
        app.launch()
        // Canvas is up once the state hook and the root node element exist.
        XCTAssertTrue(
            element("canvas.state").waitForExistence(timeout: 15),
            "canvas.state hook never appeared — canvas did not come up")
        XCTAssertTrue(
            element("node.\(rootId)").waitForExistence(timeout: 10),
            "root node hook never appeared")
    }

    // MARK: - Happy paths

    /// Canvas renders after launch: legend + input pill visible, nothing selected.
    func testCanvasRendersAfterLaunch() throws {
        XCTAssertTrue(element("canvas.legend").waitForExistence(timeout: 5))
        XCTAssertTrue(element("input.pill").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForState { $0.contains("selected=none") })
        // Every sample-tree node got a hook element (13 nodes in job-offer.json).
        XCTAssertTrue(element("node.\(counterId)").exists)
    }

    /// Tap a node → minimal footer: title, one-sentence move, EV line, collapsed
    /// ▸ DISTRIBUTION, OPEN IN CHAT →; legend replaced (§2.3).
    func testTapNodeShowsMinimalFooter() throws {
        selectNode(counterId)

        let title = element("footer.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(
            title.label.contains("counter at 185k"),
            "footer title was '\(title.label)'")

        let move = element("footer.move")
        XCTAssertTrue(move.exists)
        XCTAssertEqual(move.label, "Counter with 185k base plus the same equity.")

        let ev = element("footer.ev")
        XCTAssertTrue(ev.exists)
        XCTAssertTrue(ev.label.hasPrefix("EV ≈"), "EV line was '\(ev.label)'")

        let toggle = element("footer.distribution.toggle")
        XCTAssertTrue(toggle.exists)
        XCTAssertTrue(toggle.label.contains("▸ DISTRIBUTION"), "toggle was '\(toggle.label)'")

        XCTAssertTrue(element("footer.openInChat").exists)
        // The legend is replaced by the footer, not stacked with it.
        XCTAssertFalse(element("canvas.legend").exists)
    }

    /// Expand distribution → bars + single caption visible and OPEN IN CHAT is
    /// displaced; collapse (tap the histogram) restores it (§2.3).
    func testDistributionExpandDisplacesOpenInChatAndCollapseRestoresIt() throws {
        selectNode(counterId)

        let toggle = element("footer.distribution.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()

        let caption = element("footer.distribution.caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(
            caption.label.contains("of futures · tap to collapse"),
            "caption was '\(caption.label)'")
        XCTAssertTrue(element("footer.distribution.histogram").exists)
        XCTAssertTrue(toggle.label.contains("▾ DISTRIBUTION"), "toggle was '\(toggle.label)'")
        // While expanded, OPEN IN CHAT is temporarily displaced.
        XCTAssertFalse(element("footer.openInChat").exists)

        // The expanded footer collapses from the histogram itself ("tap to collapse").
        caption.tap()
        XCTAssertTrue(element("footer.openInChat").waitForExistence(timeout: 5))
        XCTAssertFalse(element("footer.distribution.caption").exists)
        XCTAssertTrue(toggle.label.contains("▸ DISTRIBUTION"))
    }

    /// Tapping the void deselects: footer gives way to the legend again (§2.3).
    func testVoidTapDeselects() throws {
        selectNode(counterId)
        XCTAssertFalse(element("canvas.legend").exists)

        tapVoid()
        XCTAssertTrue(
            waitForState { $0.contains("selected=none") },
            "void tap did not deselect; state=\(canvasState())")
        XCTAssertTrue(element("canvas.legend").waitForExistence(timeout: 5))
        XCTAssertFalse(element("footer.title").exists)
    }

    /// Press-and-hold ≥700ms marks the node reached (realized path root→node);
    /// holding a reached node again unmarks it (§2.3).
    func testHoldMarksReachedAndSecondHoldUnmarks() throws {
        XCTAssertTrue(waitForState { $0.contains("reached=0") })

        // 0.25s recognizer delay + 0.7s ring fill, plus slack.
        holdNode(counterId, duration: 1.5)
        XCTAssertTrue(
            waitForState { $0.contains("reached=2") },
            "hold did not mark the path root→counter; state=\(canvasState())")

        // Hold again → the ring drains → unmark (path collapses to empty:
        // a bare root entry is not a meaningful mark).
        holdNode(counterId, duration: 1.5)
        XCTAssertTrue(
            waitForState { $0.contains("reached=0") },
            "second hold did not unmark; state=\(canvasState())")
    }

    /// Early release (<700ms of ring fill) cancels harmlessly: no mark, no
    /// selection change (§2.3).
    func testEarlyReleaseCancelsHoldWithoutMarking() throws {
        XCTAssertTrue(waitForState { $0.contains("reached=0") })

        // Long enough for the recognizer (0.25s) and ring to start, released
        // well before the 0.7s fill completes.
        holdNode(counterId, duration: 0.5)

        // Give any (incorrect) mark or selection a moment to land, then assert
        // that neither did.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(
            canvasState().contains("reached=0"),
            "early release still marked; state=\(canvasState())")
        XCTAssertTrue(
            canvasState().contains("selected=none"),
            "early release changed selection; state=\(canvasState())")
    }

    // MARK: - Helpers

    /// Identifier lookup across element types (SwiftUI maps identifiers onto
    /// varying XCUIElement types).
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func canvasState() -> String {
        element("canvas.state").value as? String ?? ""
    }

    /// Poll the canvas.state hook until `predicate` holds (generous, retry-based
    /// by design — §8 allows pragmatic waits, not pragmatic assertions).
    @discardableResult
    private func waitForState(
        timeout: TimeInterval = 6, _ predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(canvasState()) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return predicate(canvasState())
    }

    /// Tap a node via its hook element (which passes through to the real
    /// SCNView picking path) and wait until the store confirms the selection.
    /// Retries a few times: nodes drift slowly under ambient rotation.
    private func selectNode(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let node = element("node.\(id)")
        XCTAssertTrue(
            node.waitForExistence(timeout: 8), "node hook \(id) missing",
            file: file, line: line)
        for _ in 0..<3 {
            node.tap()
            if waitForState(timeout: 3, { $0.contains("selected=\(id)") }) { return }
        }
        XCTFail(
            "node \(id) never became selected; state=\(canvasState())",
            file: file, line: line)
    }

    private func holdNode(_ id: String, duration: TimeInterval) {
        let node = element("node.\(id)")
        XCTAssertTrue(node.waitForExistence(timeout: 8), "node hook \(id) missing")
        node.press(forDuration: duration)
    }

    /// Tap a screen point that is far from every node hook and from the
    /// overlays: resolves as a void tap → deselect.
    private func tapVoid() {
        let frame = app.frame
        // Candidate points avoiding the top-left home button, bottom overlays,
        // and screen edges; picked dynamically so tree drift can't break this.
        let candidates = [
            CGPoint(x: frame.maxX - 30, y: frame.minY + 80),
            CGPoint(x: frame.minX + 30, y: frame.midY),
            CGPoint(x: frame.maxX - 30, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY + 60),
        ]
        let nodeElements = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'node.'"))
            .allElementsBoundByIndex
        let centers = nodeElements.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }

        let target =
            candidates.first { point in
                centers.allSatisfy { hypot($0.x - point.x, $0.y - point.y) > 60 }
            } ?? candidates[0]

        let normalized = CGVector(
            dx: (target.x - frame.minX) / frame.width,
            dy: (target.y - frame.minY) / frame.height)
        app.coordinate(withNormalizedOffset: normalized).tap()
    }
}
