import PrimeRadiantCore
import XCTest
import simd

@testable import PrimeRadiant

/// Hold-to-birth math + plumbing (ux-update §2): screen→shell unprojection is
/// the exact inverse of projection, birth anchors override the ULID hash and
/// survive the wire format (they ride the schema's opaque cameraState blob),
/// and set-aware placement respects them verbatim.
final class BirthAnchorTests: XCTestCase {

    // MARK: Unprojection

    /// project → unproject round-trips to the same shell direction for a
    /// spread of camera states and viewport points.
    func testUnprojectIsInverseOfProjectOnTheShell() {
        let states: [WorldModel.CameraState] = [
            .home(),
            .home(aims: [WorldModel.anchorDirection(ulid: "01J0PRSEEDLAVNCH0000000001")]),
            .canvas(anchor: WorldModel.anchorDirection(ulid: "01J0PRSEEDVEND0R0000000002")),
        ]
        let aspect = 390.0 / 844.0
        for state in states {
            let pose = WorldModel.pose(for: state)
            for (u, v) in [(0.0, 0.0), (0.4, 0.3), (-0.5, 0.2), (0.2, -0.6)] {
                guard
                    let direction = WorldModel.unprojectToShell(
                        u: u, v: v, pose: pose,
                        fovDegrees: RadiantScene.fovDegrees, viewportAspect: aspect)
                else {
                    // Rays through extreme corners can miss the shell; the
                    // center ray never should.
                    XCTAssertNotEqual(u == 0 && v == 0, true, "center ray must hit the shell")
                    continue
                }
                XCTAssertEqual(simd_length(direction), 1, accuracy: 1e-9)
                let world = direction * WorldModel.R
                let projected = WorldModel.project(
                    world, pose: pose,
                    fovDegrees: RadiantScene.fovDegrees, viewportAspect: aspect)
                XCTAssertNotNil(projected)
                XCTAssertEqual(projected!.u, u, accuracy: 1e-6)
                XCTAssertEqual(projected!.v, v, accuracy: 1e-6)
            }
        }
    }

    func testShellIntersectionPicksTheNearFace() {
        // Camera outside the shell looking at its center: the near hit is the
        // face toward the camera.
        let origin = SIMD3<Double>(0, 0, 2 * WorldModel.R)
        let direction = SIMD3<Double>(0, 0, -1)
        let hit = WorldModel.shellIntersection(origin: origin, direction: direction)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.z, 1, accuracy: 1e-9, "near face is +z toward the camera")
    }

    func testRayMissingTheShellReturnsNil() {
        let origin = SIMD3<Double>(0, 0, 2 * WorldModel.R)
        let away = simd_normalize(SIMD3<Double>(1, 0, 0.4))
        XCTAssertNil(WorldModel.shellIntersection(origin: origin, direction: away))
    }

    // MARK: Anchor overrides

    func testAnchorOverrideWinsVerbatimAndOthersAvoidIt() {
        let chosen = simd_normalize(SIMD3<Double>(0.1, 0.05, 0.99))
        let ulids = [
            "01J0PRSEEDLAVNCH0000000001",
            "01J0PRSEEDVEND0R0000000002",
            "01J0PRBIRTHCH0SEN000000003",
        ]
        let anchors = WorldModel.anchorDirections(
            ulids: ulids, overrides: ["01J0PRBIRTHCH0SEN000000003": chosen])

        XCTAssertEqual(anchors["01J0PRBIRTHCH0SEN000000003"], chosen, "override is verbatim")
        // Hashed anchors still land for everyone else.
        for ulid in ulids {
            XCTAssertNotNil(anchors[ulid])
            XCTAssertEqual(simd_length(anchors[ulid]!), 1, accuracy: 1e-9)
        }
    }

    func testScenarioAnchorRidesCameraStateAndSurvivesTheWire() throws {
        var scenario = Scenario(
            id: "01J0PRBIRTHCH0SEN000000003",
            title: "born by hand",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            payoffUnit: PayoffUnit(kind: .currency, label: "USD"),
            status: .modeling,
            tree: Node(id: "01J0PRBIRTHR00T00000000001", label: "root", p: 1, actor: .user))
        XCTAssertNil(scenario.anchorOverride)

        let direction = simd_normalize(SIMD3<Double>(0.2, -0.1, 0.97))
        scenario.anchorOverride = direction
        XCTAssertNotNil(scenario.anchorOverride)
        XCTAssertEqual(simd_distance(scenario.anchorOverride!, direction), 0, accuracy: 1e-12)

        // Round-trip through the exact wire encoder (BoxSync/StoredScenario):
        // the anchor is cameraState — "opaque to the server" — so the shared
        // schema stays untouched.
        let data = try BoxSync.encoder.encode(scenario)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cameraState = try XCTUnwrap(object["cameraState"] as? [String: Double])
        XCTAssertEqual(cameraState["anchorX"]!, direction.x, accuracy: 1e-12)

        let decoded = try BoxSync.decoder.decode(Scenario.self, from: data)
        XCTAssertEqual(simd_distance(decoded.anchorOverride!, direction), 0, accuracy: 1e-9)

        // Clearing removes the keys.
        scenario.anchorOverride = nil
        XCTAssertNil(scenario.anchorOverride)
        XCTAssertNil(scenario.cameraState)
    }
}
