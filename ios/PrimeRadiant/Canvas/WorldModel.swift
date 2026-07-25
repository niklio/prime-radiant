import Foundation
import PrimeRadiantCore
import simd

/// Pure math for the single-void world model (notes §1): the spherical shell,
/// deterministic scenario anchors, the tree→shell mapping, the two-state camera
/// rig, projection, and the depth-cue functions. Deliberately free of SceneKit
/// so every invariant (near/far size ratio, DoF threshold, pan-not-zoom) is
/// unit-testable over the same code the renderer runs.
///
/// Coordinate/units doctrine: 1 scene unit == 1 layout unit; the shell has
/// radius R = 280 (Tokens.World.shellRadius). Magnitudes in the hundreds are
/// comfortably inside Float precision for SceneKit; the camera's zFar covers
/// the outermost nebula sphere.
enum WorldModel {

    static var R: Double { Tokens.World.shellRadius }

    // MARK: - Deterministic anchors (stable across launches)

    /// Half-angle of the spherical cap the constellations live on, radians.
    /// Sized so the whole field (plus labels) sits inside the home viewport
    /// at 1.5R with the 62° camera.
    static let anchorCapRadians = 0.30
    /// The cap's central axis; the home camera aims here.
    static let capAxis = SIMD3<Double>(0, 0, 1)

    /// Stable 64-bit FNV-1a → [0,1). Never use Hasher (seeded per-launch).
    static func hash01(_ string: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Double(hash >> 11) / Double(1 << 53)
    }

    /// A scenario's persistent shell direction, derived from its ULID alone so
    /// placement never depends on the set of scenarios present (golden-angle-
    /// style distribution: sqrt-uniform over the cap disc, uniform azimuth).
    static func anchorDirection(ulid: String) -> SIMD3<Double> {
        let radial = anchorCapRadians * hash01(ulid + "/r2").squareRoot()
        let azimuth = 2 * .pi * hash01(ulid + "/a2")
        let sinR = sin(radial)
        return SIMD3(sinR * cos(azimuth), sinR * sin(azimuth), cos(radial))
    }

    /// Tangent frame at a shell direction: `right`/`north` span the tangent
    /// plane, `out` is the outward normal. Tree-local x/y/z map onto these.
    struct Frame {
        var right: SIMD3<Double>
        var north: SIMD3<Double>
        var out: SIMD3<Double>
    }

    static func frame(at direction: SIMD3<Double>) -> Frame {
        let out = simd_normalize(direction)
        var right = simd_cross(SIMD3(0, 1, 0), out)
        if simd_length(right) < 1e-6 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let north = simd_normalize(simd_cross(out, right))
        return Frame(right: right, north: north, out: out)
    }

    // MARK: - Tree → constellation mapping

    /// Layout-units of constellation per RadiantLayout unit. Sized so the
    /// sample tree spans ~3/4 of the canvas viewport width (mock 4) and its
    /// depth run produces the ≥1.3 near/far projected-size ratio (verified by
    /// DepthVerificationTests — tune there, not by eye).
    static let treeScale = 12.0
    /// Depth-1 subtrees roll out of the fan plane about the local y axis by a
    /// stable per-branch angle, giving equal-depth siblings real depth spread
    /// (shell curvature alone is ~5% at this framing — measured; the roll
    /// supplies the rest deterministically from the branch id).
    static let maxBranchRoll = 0.55

    /// Node id → depth-1 ancestor id (its "branch"), for the branch roll.
    static func branchMap(tree: Node) -> [String: String] {
        var map: [String: String] = [:]
        func walk(_ node: Node, branch: String?) {
            if let branch { map[node.id] = branch }
            for child in node.children ?? [] {
                walk(child, branch: branch ?? child.id)
            }
        }
        walk(tree, branch: nil)
        return map
    }

    /// Map the pure 2D radial-sector layout into tree-local 3D (x=right,
    /// y=north/away-from-camera, z=out of the shell). Deterministic for a
    /// given tree: branch rolls hash from child ids.
    static func treeLocalPositions(
        layout: [String: RadiantLayout.Vector3],
        rootId: String,
        branchOf: [String: String]
    ) -> [String: SIMD3<Double>] {
        var rolls: [String: Double] = [:]
        var result: [String: SIMD3<Double>] = [:]
        for (id, p) in layout {
            let scaled = SIMD3(p.x, p.y, p.z) * treeScale
            var position = scaled
            if id != rootId, let branch = branchOf[id] {
                let roll: Double
                if let cached = rolls[branch] {
                    roll = cached
                } else {
                    roll = maxBranchRoll * (hash01(branch + "/roll") * 2 - 1)
                    rolls[branch] = roll
                }
                // Rotate about the local y axis through the root.
                let c = cos(roll)
                let s = sin(roll)
                position = SIMD3(scaled.x * c + scaled.z * s, scaled.y, -scaled.x * s + scaled.z * c)
            }
            // Shell curvature: tangent offsets drop below the tangent plane.
            position.z -= (position.x * position.x + position.y * position.y) / (2 * R)
            result[id] = position
        }
        return result
    }

    /// Tree-local → world, given the scenario's shell anchor direction.
    static func worldPosition(
        local: SIMD3<Double>, anchor: SIMD3<Double>
    ) -> SIMD3<Double> {
        let f = frame(at: anchor)
        return anchor * R + f.right * local.x + f.north * local.y + f.out * local.z
    }

    // MARK: - Camera rig (one rig, two reference states — notes §1)

    /// Complete camera state: where on the shell it aims, how far off it sits,
    /// its elevation above the tangent plane, and the user's orbit azimuth.
    /// Pan is a tangent-plane aim offset (the §3 gentle-pan invariant: pan,
    /// never zoom, on selection).
    struct CameraState {
        /// Unit direction of the aimed shell point.
        var anchor: SIMD3<Double>
        /// Aim offset from the anchor point, tangent units (right, north, out).
        var aimOffset: SIMD3<Double> = .zero
        /// Camera distance from the aim point.
        var distance: Double
        /// Tilt off the shell's outward normal, radians (0 = face-on to the
        /// shell; larger = more oblique/raking). Mock-verified: home 0.22
        /// reads face-on constellations; canvas 0.58 is the raking view.
        var tilt: Double
        /// User orbit azimuth about the aim point's outward normal.
        var yaw: Double = 0

        static func home() -> CameraState {
            CameraState(
                anchor: capAxis,
                distance: Tokens.World.homeDistanceFactor * Tokens.World.shellRadius,
                tilt: Tokens.World.homeTiltRadians)
        }

        static func canvas(anchor: SIMD3<Double>, aimOffset: SIMD3<Double> = .zero) -> CameraState {
            CameraState(
                anchor: anchor,
                aimOffset: aimOffset,
                distance: Tokens.World.canvasDistanceFactor * Tokens.World.shellRadius,
                tilt: Tokens.World.canvasTiltRadians)
        }
    }

    struct Pose {
        var position: SIMD3<Double>
        /// Orthonormal camera axes: forward is the view direction.
        var forward: SIMD3<Double>
        var right: SIMD3<Double>
        var up: SIMD3<Double>
        var aim: SIMD3<Double>
    }

    /// The rig math: the camera sits `distance` from the aim point, tilted
    /// `tilt` off the outward normal toward the near (south) side, swung
    /// `yaw` about the normal, looking at the aim point with up ≈ outward.
    /// The tree extends north — away from the viewer — so tree depth recedes
    /// into the frame (the oblique view in the mocks).
    static func pose(for state: CameraState) -> Pose {
        let f = frame(at: state.anchor)
        let aim =
            state.anchor * R
            + f.right * state.aimOffset.x
            + f.north * state.aimOffset.y
            + f.out * state.aimOffset.z
        // Offset direction in the tangent frame, swung by yaw about `out`.
        let cy = cos(state.yaw)
        let sy = sin(state.yaw)
        let south = -(f.north * cy + f.right * sy)
        let offset = f.out * cos(state.tilt) + south * sin(state.tilt)
        let position = aim + offset * state.distance
        let forward = simd_normalize(aim - position)
        var right = simd_cross(forward, f.out)
        if simd_length(right) < 1e-6 { right = f.right }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(right, forward))
        return Pose(position: position, forward: forward, right: right, up: up, aim: aim)
    }

    /// Interpolate between camera states (flight math): slerp the anchor,
    /// lerp the scalars. `t` is already eased.
    static func interpolate(_ a: CameraState, _ b: CameraState, t: Double) -> CameraState {
        var state = b
        state.anchor = slerp(a.anchor, b.anchor, t: t)
        state.aimOffset = a.aimOffset + (b.aimOffset - a.aimOffset) * t
        state.distance = a.distance + (b.distance - a.distance) * t
        state.tilt = a.tilt + (b.tilt - a.tilt) * t
        state.yaw = a.yaw + (b.yaw - a.yaw) * t
        return state
    }

    static func slerp(
        _ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double
    ) -> SIMD3<Double> {
        let na = simd_normalize(a)
        let nb = simd_normalize(b)
        let dot = max(-1, min(1, simd_dot(na, nb)))
        let theta = acos(dot)
        if theta < 1e-6 { return nb }
        let sinTheta = sin(theta)
        return simd_normalize(na * (sin((1 - t) * theta) / sinTheta) + nb * (sin(t * theta) / sinTheta))
    }

    // MARK: - Projection + depth cues

    struct Projection {
        /// Normalized viewport coordinates: |u| ≤ 1 and |v| ≤ 1 is on-screen.
        var u: Double
        var v: Double
        /// Distance along the view axis (positive in front of the camera).
        var depth: Double
    }

    static func project(
        _ point: SIMD3<Double>, pose: Pose,
        fovDegrees: Double, viewportAspect: Double
    ) -> Projection? {
        let rel = point - pose.position
        let depth = simd_dot(rel, pose.forward)
        guard depth > 0 else { return nil }
        let tanV = tan(fovDegrees / 2 * .pi / 180)
        let tanH = tanV * viewportAspect
        return Projection(
            u: simd_dot(rel, pose.right) / (depth * tanH),
            v: simd_dot(rel, pose.up) / (depth * tanV),
            depth: depth)
    }

    /// Projected scale of a node relative to one at the focus distance:
    /// perspective makes size ∝ 1/depth.
    static func projectedScale(depth: Double, focusDepth: Double) -> Double {
        guard depth > 0 else { return 0 }
        return focusDepth / depth
    }

    /// Depth dimming (notes §1 cue 2): opacity ∝ clamp(scale^1.9, 0.34, 1).
    static func depthOpacity(projectedScale: Double) -> Double {
        min(1, max(Tokens.World.dimmingFloor, pow(max(0, projectedScale), Tokens.World.dimmingExponent)))
    }

    /// DoF model (notes §1 cue 3): nodes below projected scale 0.88 blur.
    /// The renderer's SCNCamera DoF is tuned to this; the threshold itself is
    /// asserted by the depth-verification test.
    static func isBlurred(projectedScale: Double) -> Bool {
        projectedScale < Tokens.World.dofBlurBelowProjectedScale
    }
}
