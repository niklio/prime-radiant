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

    /// Canvas renders after launch: the composer capsule is docked (idle —
    /// no ribbon, no title row), nothing selected. No legend exists (mock 4).
    func testCanvasRendersAfterLaunch() throws {
        XCTAssertTrue(element("canvas.capsule").waitForExistence(timeout: 5))
        XCTAssertTrue(element("capsule.composer").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForState { $0.contains("selected=none") })
        XCTAssertFalse(element("canvas.ribbon").exists)
        XCTAssertFalse(element("capsule.title").exists)
        // Every sample-tree node got a hook element (13 nodes in job-offer.json).
        XCTAssertTrue(element("node.\(counterId)").exists)
    }

    /// Tap a node → the capsule gains its context row (mock 5): serif title,
    /// amber EV line, collapsed ▸ toggle — and the path ribbon appears above.
    func testTapNodeShowsCapsuleContextAndRibbon() throws {
        selectNode(counterId)

        let title = element("capsule.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(
            title.label.contains("ounter at 185k"),
            "capsule title was '\(title.label)'")

        let ev = element("capsule.ev")
        XCTAssertTrue(ev.exists)
        XCTAssertTrue(ev.label.hasPrefix("EV ≈"), "EV line was '\(ev.label)'")

        let toggle = element("capsule.distribution.toggle")
        XCTAssertTrue(toggle.exists)
        XCTAssertTrue(toggle.label.contains("▸"), "toggle was '\(toggle.label)'")

        // Ribbon renders the real selected path, current node last (mock 5).
        XCTAssertTrue(element("canvas.ribbon").waitForExistence(timeout: 5))
        XCTAssertTrue(element("ribbon.item.0").label.contains("OFFER IN HAND"))
        XCTAssertTrue(element("ribbon.item.1").label.contains("COUNTER AT 185K"))
    }

    /// Tap EV/▸ → the luminous ridge expands inside the capsule with the single
    /// `…% of futures` caption; tap ▾ → it collapses again (mock 6, notes §2).
    func testDistributionRidgeExpandsAndCollapses() throws {
        selectNode(counterId)

        let toggle = element("capsule.distribution.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()

        let caption = element("capsule.ridge.caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(
            caption.label.hasSuffix("of futures"),
            "caption was '\(caption.label)'")
        XCTAssertTrue(element("capsule.ridge").exists)
        XCTAssertTrue(toggle.label.contains("▾"), "toggle was '\(toggle.label)'")

        toggle.tap()
        XCTAssertTrue(waitFor { !element("capsule.ridge").exists })
        XCTAssertTrue(toggle.label.contains("▸"), "toggle was '\(toggle.label)'")
    }

    /// Tapping the void deselects: ribbon and title row give way; the capsule
    /// returns to the idle composer (§2.3).
    func testVoidTapDeselects() throws {
        selectNode(counterId)
        XCTAssertTrue(element("canvas.ribbon").waitForExistence(timeout: 5))

        tapVoid()
        XCTAssertTrue(
            waitForState { $0.contains("selected=none") },
            "void tap did not deselect; state=\(canvasState())")
        XCTAssertTrue(waitFor { !element("canvas.ribbon").exists })
        XCTAssertFalse(element("capsule.title").exists)
        XCTAssertTrue(element("canvas.capsule").exists)
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
    /// Poll an arbitrary condition (element disappearance etc.).
    @discardableResult
    private func waitFor(
        timeout: TimeInterval = 6, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

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
