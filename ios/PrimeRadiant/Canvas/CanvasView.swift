import PrimeRadiantCore
import SceneKit
import SwiftUI

/// What a completed press-and-hold means for a given node (handoff §2.3):
/// mark reached, unmark (ring drains), or the resolve flow on a terminal.
enum HoldIntent {
    case mark
    case unmark
    case resolve
}

struct CanvasCallbacks {
    var onSelect: (String?) -> Void = { _ in }
    var holdIntent: (String) -> HoldIntent = { _ in .mark }
    var onHoldCompleted: (String, HoldIntent) -> Void = { _, _ in }
}

/// SCNView wrapper carrying the complete gesture lexicon (§2.3): tap selects,
/// drag orbits, pinch zooms, two-finger tap / void tap deselects, press-and-hold
/// marks reality. No buttons, no menus, no on-screen instructions — ever.
struct CanvasView: UIViewRepresentable {
    let radiant: RadiantScene
    var interactive: Bool = true
    var callbacks = CanvasCallbacks()

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = radiant.scene
        view.backgroundColor = UIColor(hex: 0x050510)
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.pointOfView = radiant.cameraNode

        guard interactive else {
            // Ghost view (chat ambience): renders the shared scene but never
            // drives advance() and never receives touches.
            view.isUserInteractionEnabled = false
            return view
        }
        view.delegate = context.coordinator

        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        let twoFingerTap = UITapGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.twoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.pinch(_:)))
        let hold = UILongPressGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 14

        for gesture in [tap, twoFingerTap, pan, pinch, hold] {
            gesture.delegate = coordinator
            view.addGestureRecognizer(gesture)
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.callbacks = callbacks
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(radiant: radiant, callbacks: callbacks)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
        private let radiant: RadiantScene
        var callbacks: CanvasCallbacks

        // Hold-to-mark state.
        private var holdNodeId: String?
        private var holdIntent: HoldIntent = .mark
        private var holdStart: CFTimeInterval = 0
        private var holdProgress: Double = 0
        private var holdLink: CADisplayLink?
        private var ringTrack: CAShapeLayer?
        private var ringFill: CAShapeLayer?
        private let holdHaptics = HapticRamp()

        init(radiant: RadiantScene, callbacks: CanvasCallbacks) {
            self.radiant = radiant
            self.callbacks = callbacks
        }

        // MARK: SCNSceneRendererDelegate (render thread)

        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            radiant.advance(at: time)
        }

        // MARK: UIGestureRecognizerDelegate

        /// Gestures that begin on UI overlays must never reach canvas selection
        /// (handoff §8). SwiftUI overlays sit above the SCNView and consume their
        /// own touches; this check enforces it structurally as well.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            touch.view is SCNView
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Orbit + pinch may combine; the hold gesture stays exclusive.
            !(gestureRecognizer is UILongPressGestureRecognizer)
                && !(other is UILongPressGestureRecognizer)
        }

        // MARK: Gestures

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            // A release after the hold ring started is the hold ending, not a tap.
            guard holdNodeId == nil, holdProgress < 0.05 else { return }
            guard let view = gesture.view as? SCNView else { return }
            radiant.noteInteraction()
            let picked = pickNode(at: gesture.location(in: view), in: view)
            // Tapping the void deselects (§2.3).
            callbacks.onSelect(picked)
        }

        @objc func twoFingerTap(_ gesture: UITapGestureRecognizer) {
            radiant.noteInteraction()
            callbacks.onSelect(nil)
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            radiant.orbit(deltaX: translation.x, deltaY: translation.y)
            gesture.setTranslation(.zero, in: view)
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            radiant.zoom(scale: gesture.scale)
            gesture.scale = 1
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            switch gesture.state {
            case .began:
                guard let id = pickNode(at: gesture.location(in: view), in: view) else { return }
                beginHold(on: id, in: view)
            case .ended, .cancelled, .failed:
                // Releasing early cancels harmlessly (§2.3).
                cancelHold()
            default:
                break
            }
        }

        // MARK: Screen-space-nearest picking (handoff §8)

        /// Resolve the tap to the screen-space nearest candidate: large near nodes
        /// must not steal taps aimed at small far ones. Ray hits seed the candidate
        /// set; a 44pt-radius screen search catches thin far targets the ray missed.
        private func pickNode(at point: CGPoint, in view: SCNView) -> String? {
            var candidates = Set<String>()
            let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                if let id = hit.node.name { candidates.insert(id) }
            }
            if candidates.isEmpty {
                for id in radiant.allNodeIds {
                    if let projected = radiant.projectedPoint(of: id, in: view),
                        hypot(projected.x - point.x, projected.y - point.y) < 44 {
                        candidates.insert(id)
                    }
                }
            }
            var best: (id: String, distance: CGFloat)?
            for id in candidates {
                guard let projected = radiant.projectedPoint(of: id, in: view) else { continue }
                let distance = hypot(projected.x - point.x, projected.y - point.y)
                if best == nil || distance < best!.distance {
                    best = (id, distance)
                }
            }
            return best?.id
        }

        // MARK: Hold-to-mark: rising ring + haptic ramp (§2.3)

        private func beginHold(on id: String, in view: SCNView) {
            guard let center = radiant.projectedPoint(of: id, in: view) else { return }
            radiant.noteInteraction()
            holdNodeId = id
            holdIntent = callbacks.holdIntent(id)
            holdStart = CACurrentMediaTime()
            holdProgress = 0
            addRing(at: center, on: view)
            holdHaptics.begin()

            let link = CADisplayLink(target: self, selector: #selector(holdTick))
            link.add(to: .main, forMode: .common)
            holdLink = link
        }

        @objc private func holdTick() {
            guard holdNodeId != nil else { return }
            let elapsed = CACurrentMediaTime() - holdStart
            holdProgress = min(1, elapsed / Tokens.Layout.markHoldDurationSeconds)
            // Unmark drains the ring instead of filling it (§2.3).
            let visual = holdIntent == .unmark ? 1 - holdProgress : holdProgress
            ringFill?.strokeEnd = visual
            holdHaptics.update(progress: holdProgress)
            if holdProgress >= 1 {
                completeHold()
            }
        }

        private func completeHold() {
            guard let id = holdNodeId else { return }
            flashRing()
            holdHaptics.thud()
            let intent = holdIntent
            teardownHold()
            // Reset progress a beat later so the trailing touch-up is swallowed
            // by `tap(_:)` instead of registering as a selection.
            Task { @MainActor in self.holdProgress = 0 }
            callbacks.onHoldCompleted(id, intent)
        }

        private func cancelHold() {
            teardownHold()
            Task { @MainActor in self.holdProgress = 0 }
        }

        private func teardownHold() {
            holdLink?.invalidate()
            holdLink = nil
            holdNodeId = nil
            holdHaptics.end()
            ringTrack?.removeFromSuperlayer()
            ringTrack = nil
        }

        private func addRing(at center: CGPoint, on view: SCNView) {
            let radius: CGFloat = 32
            let path = UIBezierPath(
                arcCenter: .zero, radius: radius,
                startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)

            let track = CAShapeLayer()
            track.path = path.cgPath
            track.position = center
            track.strokeColor = UIColor(hex: 0xFFD98A).withAlphaComponent(0.2).cgColor
            track.fillColor = nil
            track.lineWidth = 2

            let fill = CAShapeLayer()
            fill.path = path.cgPath
            fill.strokeColor = UIColor(hex: 0xFFD98A).cgColor
            fill.fillColor = nil
            fill.lineWidth = 3
            fill.lineCap = .round
            fill.strokeEnd = holdIntent == .unmark ? 1 : 0
            // Drive strokeEnd directly from the display link, no implicit animation.
            fill.actions = ["strokeEnd": NSNull()]
            track.addSublayer(fill)

            view.layer.addSublayer(track)
            ringTrack = track
            ringFill = fill
        }

        private func flashRing() {
            guard let track = ringTrack else { return }
            let flash = CABasicAnimation(keyPath: "opacity")
            flash.fromValue = 1
            flash.toValue = 0
            flash.duration = 0.35
            track.add(flash, forKey: "flash")
        }
    }
}
