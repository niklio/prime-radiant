import PrimeRadiantCore
import SceneKit
import XCTest

@testable import PrimeRadiant

/// The §8 "interaction correctness learned the hard way" invariants, encoded as
/// unit tests over the pure functions factored out of the canvas:
/// screen-space-nearest picking, overlay exclusion, and the gentle-pan invariant.
@MainActor
final class CanvasInteractionTests: XCTestCase {

    // MARK: - Screen-space-nearest picking (§8)

    func testNearNodeDoesNotStealTapAimedAtSmallFarNode() {
        // Both nodes are ray hits (the big near node's glow swallowed the ray),
        // but the tap sits 5pt from the far node's projected center and 40pt
        // from the near one's: the far node must win.
        let picked = CanvasPicking.resolve(
            tapPoint: CGPoint(x: 100, y: 100),
            rayHitIds: ["bigNear", "smallFar"],
            projectedPoints: [
                "bigNear": CGPoint(x: 140, y: 100),
                "smallFar": CGPoint(x: 104, y: 103),
            ])
        XCTAssertEqual(picked, "smallFar")
    }

    func testRayMissFallsBackToScreenRadiusSearch() {
        // No ray hits at all; a thin far target 30pt away is still within the
        // 44pt screen-search radius and must be picked.
        let picked = CanvasPicking.resolve(
            tapPoint: CGPoint(x: 50, y: 50),
            rayHitIds: [],
            projectedPoints: [
                "thinFar": CGPoint(x: 80, y: 50),
                "wayOff": CGPoint(x: 300, y: 300),
            ])
        XCTAssertEqual(picked, "thinFar")
    }

    func testScreenSearchPicksNearestOfSeveral() {
        let picked = CanvasPicking.resolve(
            tapPoint: .zero,
            rayHitIds: [],
            projectedPoints: [
                "a": CGPoint(x: 40, y: 0),
                "b": CGPoint(x: 0, y: 10),
                "c": CGPoint(x: -20, y: -20),
            ])
        XCTAssertEqual(picked, "b")
    }

    func testVoidTapResolvesToNothing() {
        // Everything is farther than the search radius and nothing was ray-hit:
        // the tap is a void tap (deselect, §2.3).
        let picked = CanvasPicking.resolve(
            tapPoint: .zero,
            rayHitIds: [],
            projectedPoints: [
                "a": CGPoint(x: 60, y: 0),
                "b": CGPoint(x: 0, y: -100),
            ])
        XCTAssertNil(picked)
    }

    func testRayHitBeyondSearchRadiusStillResolves() {
        // A genuinely ray-hit large node can be tapped on its glow edge, farther
        // than the screen-search radius from its center — it must still resolve.
        let picked = CanvasPicking.resolve(
            tapPoint: .zero,
            rayHitIds: ["big"],
            projectedPoints: ["big": CGPoint(x: 60, y: 0)])
        XCTAssertEqual(picked, "big")
    }

    func testRayHitWithoutProjectionIsIgnored() {
        XCTAssertNil(
            CanvasPicking.resolve(
                tapPoint: .zero,
                rayHitIds: ["behindCamera"],
                projectedPoints: [:]))
    }

    // MARK: - Overlay exclusion (§8)

    func testTouchesOnCanvasReachSelection() {
        XCTAssertTrue(CanvasPicking.shouldReceiveTouch(on: SCNView()))
        XCTAssertTrue(CanvasPicking.shouldReceiveTouch(on: CanvasSCNView()))
    }

    func testTouchesBeginningOnOverlaysNeverReachSelection() {
        // SwiftUI overlay hosting views, buttons, and the DEBUG hooks overlay
        // are all plain UIViews — none may drive canvas selection.
        XCTAssertFalse(CanvasPicking.shouldReceiveTouch(on: UIView()))
        XCTAssertFalse(CanvasPicking.shouldReceiveTouch(on: UIButton()))
        XCTAssertFalse(CanvasPicking.shouldReceiveTouch(on: UILabel()))
        XCTAssertFalse(CanvasPicking.shouldReceiveTouch(on: nil))
    }

    // MARK: - Gentle-pan invariant (§8)

    /// Matches the SCNCamera configured in RadiantScene.
    private let fovDegrees = 55.0
    /// Compact iPhone portrait (390×844) and the RadiantScene default.
    private let aspects = [390.0 / 844.0, 0.47]

    /// After selection reflow + camera fit, every target position must project
    /// inside the viewport for the sample tree — for *every* possible selection.
    func testEverySelectionKeepsAllTargetsInsideViewport() throws {
        let scenario = try sampleScenario()
        var selections: [String?] = [nil]
        selections += Tree.allIds(scenario.tree).map { Optional($0) }

        for aspect in aspects {
            for selection in selections {
                let targets = RadiantLayout.targets(tree: scenario.tree, selectedId: selection)
                let framing = try XCTUnwrap(
                    CameraFit.framing(
                        positions: Array(targets.values),
                        fovDegrees: fovDegrees,
                        viewportAspect: aspect))
                for (id, position) in targets {
                    XCTAssertTrue(
                        CameraFit.projectsInsideViewport(
                            position, framing: framing,
                            fovDegrees: fovDegrees, viewportAspect: aspect),
                        "node \(id) escaped the viewport with \(selection ?? "nothing") "
                            + "selected (aspect \(aspect))")
                }
            }
        }
    }

    func testFramingClampsToMinimumDistanceForTinyTrees() throws {
        // Zero margin isolates the clamp: a single point needs no distance at
        // all, so the minimum wins (the camera never rams the root).
        let framing = try XCTUnwrap(
            CameraFit.framing(
                positions: [RadiantLayout.Vector3(x: 0, y: 0, z: 0)],
                fovDegrees: fovDegrees,
                viewportAspect: 0.47,
                margin: 0))
        XCTAssertEqual(framing.distance, 3)
        XCTAssertEqual(framing.centerY, 0)
    }

    func testFramingIsEmptySafe() {
        XCTAssertNil(CameraFit.framing(positions: [], fovDegrees: fovDegrees, viewportAspect: 0.47))
    }

    // MARK: - Support

    /// The bundled sample scenario (job-offer.json) — the same tree the UI tests
    /// drive under -PRDebugSample.
    private func sampleScenario() throws -> Scenario {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "job-offer", withExtension: "json"),
            "job-offer.json missing from the app bundle")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Scenario.self, from: Data(contentsOf: url))
    }
}
