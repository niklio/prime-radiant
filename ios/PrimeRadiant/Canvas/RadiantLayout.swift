import Foundation
import PrimeRadiantCore

/// The §3 radial-sector layout as pure functions over `PrimeRadiantCore.Node`.
///
/// Deliberately free of SceneKit/UIKit so the whole algorithm is unit-testable
/// (and can later move into the package). Numeric defaults in `Config` mirror
/// shared/tokens.json → layout; keep them in sync.
enum RadiantLayout {

    /// Minimal vector type so this file has zero rendering dependencies.
    struct Vector3: Equatable, Sendable {
        var x: Double
        var y: Double
        var z: Double
    }

    struct Config: Sendable {
        /// Total angular span of the root fan, radians (~140°).
        var totalSpan: Double = 2.45
        /// World-units of radius gained per depth level.
        var radiusStep: Double = 1.15
        /// Extra vertical lift per depth level, so wide-angle branches still climb
        /// (handoff §3: depth maps to radius *and* height).
        var heightStep: Double = 0.22
        /// Recession per depth level (into the fog, for parallax).
        var depthStep: Double = 0.16
        /// Mirrors tokens layout.minChildSectorFraction.
        var minChildSectorFraction: Double = Tokens.Layout.minChildSectorFraction
        /// Mirrors tokens layout.onPathChildWeight.
        var onPathChildWeight: Double = Tokens.Layout.onPathChildWeight
        /// Mirrors tokens layout.offPathSiblingWeight.
        var offPathSiblingWeight: Double = Tokens.Layout.offPathSiblingWeight

        init() {}
    }

    /// Target positions keyed by node id. Root sits at the origin (bottom-center;
    /// the camera frames it low). Deterministic for a given (tree, selection).
    ///
    /// Selection reweighting (§3): children on the path root→selected weigh ×3.2,
    /// their off-path siblings ×0.5; sectors renormalize; every child keeps a
    /// minimum width floor of `minChildSectorFraction` of the parent's span.
    static func targets(
        tree: Node,
        selectedId: String?,
        config: Config = Config()
    ) -> [String: Vector3] {
        // Renormalize first so `p` is trustworthy regardless of input drift.
        let root = Tree.renormalized(tree)
        let selectionPath: Set<String> =
            selectedId.flatMap { Tree.path(root, to: $0).map(Set.init) } ?? []

        var positions: [String: Vector3] = [:]

        func place(_ node: Node, depth: Int, centerAngle: Double, span: Double) {
            positions[node.id] = position(depth: depth, angle: centerAngle, config: config)
            guard let children = node.children, !children.isEmpty else { return }

            let spans = sectorSpans(
                children: children,
                parentSpan: span,
                selectionPath: selectionPath,
                config: config)

            var cursor = centerAngle - span / 2
            for (child, childSpan) in zip(children, spans) {
                place(
                    child,
                    depth: depth + 1,
                    centerAngle: cursor + childSpan / 2,
                    span: childSpan)
                cursor += childSpan
            }
        }

        place(root, depth: 0, centerAngle: 0, span: config.totalSpan)
        return positions
    }

    /// Angular spans for a sibling group, in child order; sums to `parentSpan`.
    /// Exposed for tests.
    static func sectorSpans(
        children: [Node],
        parentSpan: Double,
        selectionPath: Set<String>,
        config: Config
    ) -> [Double] {
        guard !children.isEmpty else { return [] }
        let anyOnPath = children.contains { selectionPath.contains($0.id) }
        let weights = children.map { child -> Double in
            let multiplier: Double
            if selectionPath.contains(child.id) {
                multiplier = config.onPathChildWeight
            } else if anyOnPath {
                multiplier = config.offPathSiblingWeight
            } else {
                multiplier = 1
            }
            return max(0, child.p) * multiplier
        }
        let total = weights.reduce(0, +)
        // Degenerate group (all-zero weights): split uniformly.
        let fractions = total > 0
            ? weights.map { $0 / total }
            : Array(repeating: 1.0 / Double(children.count), count: children.count)
        // Min-width floor, then renormalize so the group still fits the parent span.
        let floored = fractions.map { max($0, config.minChildSectorFraction) }
        let flooredTotal = floored.reduce(0, +)
        return floored.map { $0 / flooredTotal * parentSpan }
    }

    /// Depth + fan angle → world position. Angle 0 is straight up from the root;
    /// positive angles fan to the right.
    static func position(depth: Int, angle: Double, config: Config) -> Vector3 {
        let d = Double(depth)
        let radius = d * config.radiusStep
        return Vector3(
            x: radius * sin(angle),
            y: radius * cos(angle) + d * config.heightStep,
            z: -d * config.depthStep)
    }
}
