import SceneKit
import UIKit

/// Pure interaction-correctness logic for the canvas, factored out of the
/// gesture coordinator so it is unit-testable without a live SCNView
/// (handoff §8: "interaction correctness learned the hard way — encode as tests").
enum CanvasPicking {

    /// Screen-space-nearest picking (§8): ray hits seed the candidate set; when
    /// the ray misses everything, a screen-radius search catches thin far targets.
    /// The winner is the candidate whose *projected center* is nearest the tap —
    /// large near nodes must not steal taps aimed at small far ones.
    static func resolve(
        tapPoint: CGPoint,
        rayHitIds: [String],
        projectedPoints: [String: CGPoint],
        searchRadius: CGFloat = 44
    ) -> String? {
        var candidates = Set(rayHitIds)
        if candidates.isEmpty {
            for (id, projected) in projectedPoints
            where hypot(projected.x - tapPoint.x, projected.y - tapPoint.y) < searchRadius {
                candidates.insert(id)
            }
        }
        var best: (id: String, distance: CGFloat)?
        for id in candidates {
            guard let projected = projectedPoints[id] else { continue }
            let distance = hypot(projected.x - tapPoint.x, projected.y - tapPoint.y)
            if best == nil || distance < best!.distance {
                best = (id, distance)
            }
        }
        return best?.id
    }

    /// Overlay exclusion (§8): gestures that begin on UI overlays must never
    /// reach canvas selection logic. Only touches landing on the SCNView itself
    /// may drive canvas gestures; anything else (SwiftUI overlay hosting views,
    /// buttons, the DEBUG hooks overlay) is excluded.
    static func shouldReceiveTouch(on view: UIView?) -> Bool {
        view is SCNView
    }
}
