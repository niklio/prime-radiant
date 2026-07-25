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

    // MARK: - Gentle-pan invariant (notes §3: pan, never zoom, on selection)

    /// Matches the SCNCamera configured in RadiantScene.
    private let fovDegrees = RadiantScene.fovDegrees
    /// Compact iPhone portrait (390×844) and a slightly narrower guard.
    private let aspects = [390.0 / 844.0, 0.44]
    private var canvasDistance: Double {
        Tokens.World.canvasDistanceFactor * Tokens.World.shellRadius
    }
    private var canvasTilt: Double { Tokens.World.canvasTiltRadians }

    /// For *every* possible selection, the pan chosen by CameraFit must keep
    /// the selected node and its children inside the viewport at the FIXED
    /// canvas distance — the camera pans, it never zooms (the distance is not
    /// even an output of the fit).
    func testEverySelectionPansSelectedNodeAndChildrenIntoViewport() throws {
        let scenario = try sampleScenario()
        let branchOf = WorldModel.branchMap(tree: scenario.tree)

        for aspect in aspects {
            for selection in Tree.allIds(scenario.tree) {
                let layout = RadiantLayout.targets(tree: scenario.tree, selectedId: selection)
                let locals = WorldModel.treeLocalPositions(
                    layout: layout, rootId: scenario.tree.id, branchOf: branchOf)
                let selected = try XCTUnwrap(Tree.find(scenario.tree, id: selection))
                let keepIds = [selection] + (selected.children ?? []).map(\.id)
                let keep = keepIds.compactMap { locals[$0] }
                let offset = try XCTUnwrap(
                    CameraFit.aimOffset(
                        keep: keep, distance: canvasDistance, tilt: canvasTilt,
                        fovDegrees: fovDegrees, viewportAspect: aspect))
                XCTAssertTrue(
                    CameraFit.fits(
                        keep: keep, aimOffset: offset, distance: canvasDistance,
                        tilt: canvasTilt, fovDegrees: fovDegrees, viewportAspect: aspect),
                    "selection \(selection) escaped the viewport (aspect \(aspect))")
            }
        }
    }

    /// With nothing selected the whole constellation is framed by the same
    /// pan-only fit (arrival framing after the dive).
    func testIdleFramingKeepsWholeTreeInViewport() throws {
        let scenario = try sampleScenario()
        let layout = RadiantLayout.targets(tree: scenario.tree, selectedId: nil)
        let locals = WorldModel.treeLocalPositions(
            layout: layout, rootId: scenario.tree.id,
            branchOf: WorldModel.branchMap(tree: scenario.tree))
        let keep = Array(locals.values)

        for aspect in aspects {
            let offset = try XCTUnwrap(
                CameraFit.aimOffset(
                    keep: keep, distance: canvasDistance, tilt: canvasTilt,
                    fovDegrees: fovDegrees, viewportAspect: aspect))
            XCTAssertTrue(
                CameraFit.fits(
                    keep: keep, aimOffset: offset, distance: canvasDistance,
                    tilt: canvasTilt, fovDegrees: fovDegrees, viewportAspect: aspect),
                "idle framing escaped the viewport (aspect \(aspect))")
        }
    }

    func testAimOffsetIsEmptySafe() {
        XCTAssertNil(
            CameraFit.aimOffset(
                keep: [], distance: canvasDistance, tilt: canvasTilt,
                fovDegrees: fovDegrees, viewportAspect: 0.47))
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
