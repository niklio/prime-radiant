import SwiftUI
import UIKit

/// The one hold-ring, everywhere (ux-update §3): every hold gesture in the app
/// renders the identical ring — track circle r=26pt, amber, 2px, 22% opacity;
/// gold fill arc, 2.4px, round caps, sweeping clockwise from 12 o'clock. No
/// decorations — no motes, trails, arrows, or halos, ever. Contexts differ only
/// in duration and what sits beneath the ring.
///
/// Under Reduce Motion the ring fills in opacity steps instead of sweeping.
@MainActor
final class HoldRingLayer: CALayer {

    static let radius: CGFloat = 26
    static let trackWidth: CGFloat = 2
    static let trackOpacity: Float = 0.22
    static let fillWidth: CGFloat = 2.4
    /// Opacity quantization for the Reduce Motion fill (steps, not a sweep).
    static let reduceMotionSteps: Double = 5

    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let reduceMotion: Bool

    init(reduceMotion: Bool = Motion.isReduced) {
        self.reduceMotion = reduceMotion
        super.init()

        // Clockwise from 12 o'clock.
        let path = UIBezierPath(
            arcCenter: .zero, radius: Self.radius,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)

        track.path = path.cgPath
        track.strokeColor = TokenColors.filamentAmber.cgColor
        track.opacity = Self.trackOpacity
        track.fillColor = nil
        track.lineWidth = Self.trackWidth
        addSublayer(track)

        fill.path = path.cgPath
        fill.strokeColor = TokenColors.ignitedGold.cgColor
        fill.fillColor = nil
        fill.lineWidth = Self.fillWidth
        fill.lineCap = .round
        fill.strokeEnd = 0
        // Progress is driven externally (display link / SwiftUI state); no
        // implicit animations.
        fill.actions = ["strokeEnd": NSNull(), "opacity": NSNull()]
        addSublayer(fill)
    }

    override init(layer: Any) {
        self.reduceMotion = (layer as? HoldRingLayer)?.reduceMotion ?? false
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 0…1 fill progress. Sweeps the gold arc; under Reduce Motion the full
    /// circle steps up in opacity instead.
    var progress: Double = 0 {
        didSet {
            let clamped = min(1, max(0, progress))
            if reduceMotion {
                fill.strokeEnd = 1
                fill.opacity = Float(
                    (clamped * Self.reduceMotionSteps).rounded(.down) / Self.reduceMotionSteps)
            } else {
                fill.strokeEnd = clamped
                fill.opacity = 1
            }
        }
    }

    /// Early release: the ring drains fast (~150ms), no completion haptic
    /// (notes §3). Removes the layer when the drain lands.
    func drain() {
        let duration = Tokens.Motion.markCancelDrainSeconds
        let drain = CABasicAnimation(keyPath: reduceMotion ? "opacity" : "strokeEnd")
        drain.fromValue = reduceMotion ? fill.opacity : fill.strokeEnd
        drain.toValue = 0
        drain.duration = duration
        if reduceMotion { fill.opacity = 0 } else { fill.strokeEnd = 0 }
        fill.add(drain, forKey: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.removeFromSuperlayer()
        }
    }

    /// Completion flash (notes §3), then the ring is gone.
    func flash() {
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 1
        flash.toValue = 0
        flash.duration = 0.35
        flash.isRemovedOnCompletion = false
        flash.fillMode = .forwards
        add(flash, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.removeFromSuperlayer()
        }
    }
}

/// SwiftUI wrapper for overlay use (debug captures, future birth-hold): the
/// identical layer, positioned by the parent, progress bound to state.
struct HoldRingView: UIViewRepresentable {
    var progress: Double

    final class RingHost: UIView {
        let ring = HoldRingLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(ring)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func makeUIView(context: Context) -> RingHost { RingHost() }

    func updateUIView(_ view: RingHost, context: Context) {
        view.ring.progress = progress
    }
}
