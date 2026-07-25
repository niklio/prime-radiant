import Foundation
import simd

/// The gentle-pan invariant math, factored pure (notes §3): on selection the
/// camera may PAN — never zoom — sized so the selected node and its children
/// stay inside the viewport; deselect pans back. Distance and tilt are fixed
/// by the canvas camera state; the only degree of freedom here is the
/// tangent-plane aim offset. `RadiantScene` applies the result; unit tests
/// assert the invariant directly over the sample tree for every selection.
enum CameraFit {

    /// Fraction of the viewport the fitted points must stay inside (margin for
    /// halos and the bottom capsule stack).
    static let viewportMargin = 0.82
    /// The fit centers the kept points, biased slightly above screen center so
    /// the constellation floats over the capsule stack (mock 4).
    static let centerBiasV = 0.10

    /// Choose a tangent-plane aim offset so every `keep` position (tree-local
    /// coordinates from `WorldModel.treeLocalPositions`) projects inside the
    /// viewport at the *fixed* canvas distance/tilt. Iterative: projection
    /// under tilt is nonlinear in the pan, so we correct against measured
    /// overflow a few times (converges in 2–3 rounds; tests assert the result,
    /// not the iteration count).
    ///
    /// Returns nil when `keep` is empty. When the points cannot fit at the
    /// fixed distance (they always can for token-scaled trees; asserted by
    /// tests), the best-effort centering offset is still returned.
    static func aimOffset(
        keep: [SIMD3<Double>],
        distance: Double,
        tilt: Double,
        fovDegrees: Double,
        viewportAspect: Double
    ) -> SIMD3<Double>? {
        guard !keep.isEmpty, fovDegrees > 0, viewportAspect > 0 else { return nil }

        // Work in tree-local coordinates: anchor = +z axis at distance R below
        // is irrelevant here — build the pose directly in local space.
        var offset = centroid(of: keep)
        offset.z = 0

        for _ in 0..<8 {
            guard let box = projectedBox(
                keep: keep, aimOffset: offset, distance: distance, tilt: tilt,
                fovDegrees: fovDegrees, viewportAspect: viewportAspect)
            else { return offset }

            // Aim so the kept box is centered (biased slightly high — mock 4);
            // a centered box that fits the margin trivially satisfies `fits`.
            let uShift = (box.minU + box.maxU) / 2
            let vShift = (box.minV + box.maxV) / 2 - centerBiasV
            if abs(uShift) < 0.005 && abs(vShift) < 0.005 { break }

            // Convert normalized-viewport shift into tangent-plane units.
            // Horizontal viewport u maps to local x directly; vertical v maps
            // to local y foreshortened by the tilt — understep and iterate.
            let tanV = tan(fovDegrees / 2 * .pi / 180)
            let tanH = tanV * viewportAspect
            offset.x += uShift * distance * tanH
            offset.y += vShift * distance * tanV
        }
        return offset
    }

    /// True when every `keep` point projects inside the (margin-shrunk)
    /// viewport for the given aim offset at the fixed canvas distance/tilt.
    /// Shares the projection math with `aimOffset` by construction.
    static func fits(
        keep: [SIMD3<Double>],
        aimOffset: SIMD3<Double>,
        distance: Double,
        tilt: Double,
        fovDegrees: Double,
        viewportAspect: Double
    ) -> Bool {
        guard let box = projectedBox(
            keep: keep, aimOffset: aimOffset, distance: distance, tilt: tilt,
            fovDegrees: fovDegrees, viewportAspect: viewportAspect)
        else { return false }
        let m = viewportMargin
        return box.minU >= -m && box.maxU <= m && box.minV >= -m && box.maxV <= m
    }

    // MARK: - Internals

    private struct Box {
        var minU = Double.greatestFiniteMagnitude
        var maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude
    }

    /// Local-space camera pose for a given aim offset (mirrors
    /// `WorldModel.pose` with the identity tangent frame; tilt measured off
    /// the outward normal, matching the world rig).
    static func localPose(
        aimOffset: SIMD3<Double>, distance: Double, tilt: Double
    ) -> WorldModel.Pose {
        let aim = aimOffset
        let position = aim + SIMD3(0.0, -sin(tilt), cos(tilt)) * distance
        let forward = simd_normalize(aim - position)
        var right = simd_cross(forward, SIMD3(0, 0, 1))
        if simd_length(right) < 1e-6 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(right, forward))
        return WorldModel.Pose(position: position, forward: forward, right: right, up: up, aim: aim)
    }

    private static func projectedBox(
        keep: [SIMD3<Double>],
        aimOffset: SIMD3<Double>,
        distance: Double,
        tilt: Double,
        fovDegrees: Double,
        viewportAspect: Double
    ) -> Box? {
        let pose = localPose(aimOffset: aimOffset, distance: distance, tilt: tilt)
        var box = Box()
        for point in keep {
            guard let p = WorldModel.project(
                point, pose: pose, fovDegrees: fovDegrees, viewportAspect: viewportAspect)
            else { return nil }
            box.minU = min(box.minU, p.u)
            box.maxU = max(box.maxU, p.u)
            box.minV = min(box.minV, p.v)
            box.maxV = max(box.maxV, p.v)
        }
        return box
    }

    private static func centroid(of points: [SIMD3<Double>]) -> SIMD3<Double> {
        var lo = points[0]
        var hi = points[0]
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo + hi) / 2
    }
}
