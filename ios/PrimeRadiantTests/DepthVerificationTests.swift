import PrimeRadiantCore
import XCTest

@testable import PrimeRadiant

/// The notes §6 depth-verification test: pure math over the layout + camera
/// model (no screenshots) so the mocks' measured depth feel cannot drift.
/// Renders nothing — computes the reference sample tree's projected node
/// scales at the canvas camera state and asserts:
///   1. near/far node-size ratio ≥ 1.3 (tokens world.depth.minAssertedSizeRatio);
///   2. the DoF model blurs exactly below projected scale 0.88, and the
///      reference layout actually exercises both sides of the threshold;
///   3. the depth-dimming curve obeys opacity ∝ clamp(scale^1.9, 0.34, 1).
final class DepthVerificationTests: XCTestCase {

    private let fovDegrees = RadiantScene.fovDegrees
    private let aspect = 390.0 / 844.0
    private var distance: Double {
        Tokens.World.canvasDistanceFactor * Tokens.World.shellRadius
    }
    private var tilt: Double { Tokens.World.canvasTiltRadians }

    /// Projected scales (relative to the focus distance) for every node of the
    /// reference sample tree at the canvas camera state, idle framing.
    private func referenceScales() throws -> [String: Double] {
        let scenario = try sampleScenario()
        let layout = RadiantLayout.targets(tree: scenario.tree, selectedId: nil)
        let locals = WorldModel.treeLocalPositions(
            layout: layout, rootId: scenario.tree.id,
            branchOf: WorldModel.branchMap(tree: scenario.tree))
        let offset = try XCTUnwrap(
            CameraFit.aimOffset(
                keep: Array(locals.values), distance: distance, tilt: tilt,
                fovDegrees: fovDegrees, viewportAspect: aspect))
        let pose = CameraFit.localPose(aimOffset: offset, distance: distance, tilt: tilt)

        var scales: [String: Double] = [:]
        for (id, local) in locals {
            let p = try XCTUnwrap(
                WorldModel.project(
                    local, pose: pose, fovDegrees: fovDegrees, viewportAspect: aspect))
            scales[id] = WorldModel.projectedScale(depth: p.depth, focusDepth: distance)
        }
        return scales
    }

    // MARK: - 1. Perspective foreshortening

    /// Nearest vs farthest node of the reference layout must differ by ≥1.3×
    /// in projected size (target 1.4 — notes §1 cue 1). Measured, not styled:
    /// the ratio comes from the raking canvas tilt + branch roll + shell
    /// curvature, all in WorldModel.
    func testNearFarNodeSizeRatioMeetsFloor() throws {
        let scales = try referenceScales()
        let near = try XCTUnwrap(scales.values.max())
        let far = try XCTUnwrap(scales.values.min())
        XCTAssertGreaterThan(far, 0)
        XCTAssertGreaterThanOrEqual(
            near / far, Tokens.World.minAssertedSizeRatio,
            "near/far projected-size ratio collapsed: \(near / far)")
    }

    // MARK: - 2. Depth of field

    /// The DoF model threshold is exactly the tokens value…
    func testDoFThresholdIsAppliedBelowProjectedScale() {
        let threshold = Tokens.World.dofBlurBelowProjectedScale
        XCTAssertTrue(WorldModel.isBlurred(projectedScale: threshold - 0.001))
        XCTAssertFalse(WorldModel.isBlurred(projectedScale: threshold))
        XCTAssertFalse(WorldModel.isBlurred(projectedScale: 1.0))
    }

    /// …and the reference layout actually spans it: the deep periphery blurs
    /// while the focus region stays sharp (otherwise the cue is decorative).
    func testReferenceLayoutExercisesBothSidesOfDoFThreshold() throws {
        let scales = try referenceScales()
        XCTAssertTrue(
            scales.values.contains { WorldModel.isBlurred(projectedScale: $0) },
            "no node of the reference tree falls into DoF blur")
        XCTAssertTrue(
            scales.values.contains { !WorldModel.isBlurred(projectedScale: $0) },
            "every node of the reference tree is blurred — focus is lost")
    }

    // MARK: - 3. Depth dimming

    func testDepthDimmingCurveClampsAndFollowsExponent() {
        // In-range: scale^1.9.
        XCTAssertEqual(
            WorldModel.depthOpacity(projectedScale: 0.9),
            pow(0.9, Tokens.World.dimmingExponent), accuracy: 1e-9)
        // Clamp floor at 0.34, ceiling at 1.
        XCTAssertEqual(WorldModel.depthOpacity(projectedScale: 0.2), Tokens.World.dimmingFloor)
        XCTAssertEqual(WorldModel.depthOpacity(projectedScale: 2.0), 1.0)
    }

    // MARK: - Support

    private func sampleScenario() throws -> Scenario {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "job-offer", withExtension: "json"),
            "job-offer.json missing from the app bundle")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Scenario.self, from: Data(contentsOf: url))
    }
}
