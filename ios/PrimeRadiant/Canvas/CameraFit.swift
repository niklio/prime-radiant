import Foundation

/// The §8 gentle-pan invariant math, factored pure: given reflow targets and
/// the camera frustum, choose a distance + vertical center so every target
/// lands inside the viewport. `RadiantScene.fitCamera` applies the result;
/// unit tests assert the invariant directly over the sample tree.
enum CameraFit {

    struct Framing: Equatable {
        var distance: Double
        var centerY: Double
    }

    /// Pull the camera back until the layout's bounding box fits both axes,
    /// keeping x centered (root at bottom-center, §3). `margin` accounts for
    /// glow halos extending well past node centers.
    static func framing(
        positions: [RadiantLayout.Vector3],
        fovDegrees: Double,
        viewportAspect: Double,
        margin: Double = 1.1,
        minDistance: Double = 3,
        maxDistance: Double = 20
    ) -> Framing? {
        guard !positions.isEmpty, fovDegrees > 0, viewportAspect > 0 else { return nil }
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var maxAbsX = 0.0
        var maxZ = -Double.greatestFiniteMagnitude
        for position in positions {
            minY = min(minY, position.y)
            maxY = max(maxY, position.y)
            maxAbsX = max(maxAbsX, abs(position.x))
            maxZ = max(maxZ, position.z)
        }
        let halfHeight = (maxY - minY) / 2 + margin
        let halfWidth = maxAbsX + margin
        let tanVertical = tan(fovDegrees / 2 * .pi / 180)
        // Vertical-FOV camera: the horizontal half-angle shrinks with the aspect.
        let tanHorizontal = tanVertical * viewportAspect
        let needed = max(halfHeight / tanVertical, halfWidth / tanHorizontal) + maxZ
        return Framing(
            distance: max(minDistance, min(maxDistance, needed)),
            centerY: (minY + maxY) / 2)
    }

    /// True when `position` projects inside the frustum for `framing` (camera on
    /// the +z axis at `centerY` looking down −z — the default pose fitCamera
    /// restores). Lives next to `framing` so the projection math matches the
    /// framing math by construction; used by the gentle-pan invariant tests.
    static func projectsInsideViewport(
        _ position: RadiantLayout.Vector3,
        framing: Framing,
        fovDegrees: Double,
        viewportAspect: Double
    ) -> Bool {
        let dz = framing.distance - position.z
        guard dz > 0 else { return false }
        let tanVertical = tan(fovDegrees / 2 * .pi / 180)
        let tanHorizontal = tanVertical * viewportAspect
        return abs(position.x) <= dz * tanHorizontal
            && abs(position.y - framing.centerY) <= dz * tanVertical
    }
}
