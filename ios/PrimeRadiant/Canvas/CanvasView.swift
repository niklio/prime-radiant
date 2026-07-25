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
    /// Home mode: tapping a cluster dives into it (notes §2).
    var onTapCluster: (String) -> Void = { _ in }
}

#if DEBUG
    /// UI-test hooks, gated on the `-PRUITestHooks` launch argument (mirrors
    /// `-PRDebugSample`, handoff §8). SceneKit nodes aren't individually
    /// reachable by XCUITest, so under this flag the canvas overlays tiny
    /// non-interactive accessibility elements that track each node's projected
    /// screen position (id `node.<ulid>`, label = the node's label — the
    /// foundation for the M4 VoiceOver work, §9), plus a `canvas.state` element
    /// whose value carries selection/realized-path state. The overlay never
    /// intercepts touches, so synthesized taps/holds land on the real SCNView
    /// gesture path. Never compiled into release builds.
    enum UITestHooks {
        static let enabled = ProcessInfo.processInfo.arguments.contains("-PRUITestHooks")
    }

    struct CanvasHooksState {
        /// Node id → node label for every node currently in the tree.
        var nodeLabels: [String: String]
        /// e.g. "selected=01J… reached=2"
        var stateValue: String
    }
#endif

/// SCNView that reports its layout size so camera-fit math uses the real
/// viewport aspect (§8 gentle-pan invariant) instead of a hardcoded guess.
final class CanvasSCNView: SCNView {
    var onLayoutSize: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSize?(bounds.size)
    }
}

/// SCNView wrapper carrying the complete gesture lexicon (§2.3): tap selects,
/// drag orbits, pinch zooms, two-finger tap / void tap deselects, press-and-hold
/// marks reality. No buttons, no menus, no on-screen instructions — ever.
struct CanvasView: UIViewRepresentable {
    let radiant: RadiantScene
    var interactive: Bool = true
    var callbacks = CanvasCallbacks()
    #if DEBUG
        /// Set only when `-PRUITestHooks` is active; nil otherwise.
        var hooksState: (@MainActor () -> CanvasHooksState)?
    #endif

    func makeUIView(context: Context) -> SCNView {
        let view = CanvasSCNView()
        view.onLayoutSize = { [weak radiant] size in radiant?.setViewportSize(size) }
        view.scene = radiant.scene
        if interactive { radiant.hostView = view }
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

        #if DEBUG
            if let hooksState {
                coordinator.installHooksOverlay(on: view, stateProvider: hooksState)
            }
        #endif
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.callbacks = callbacks
        #if DEBUG
            // The SCNView persists across home↔canvas mode changes now; the
            // hooks provider must track the current store, not the one that
            // existed at makeUIView time.
            if let hooksState {
                context.coordinator.updateHooksProvider(hooksState)
            }
        #endif
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        #if DEBUG
            coordinator.teardownHooksOverlay()
        #endif
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
        private var ring: HoldRingLayer?
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
            CanvasPicking.shouldReceiveTouch(on: touch.view)
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
            let point = gesture.location(in: view)
            switch radiant.currentMode {
            case .home:
                // Tap a cluster → dive (the same scene; only the camera flies).
                let points = radiant.clusterScreenPoints(in: view)
                var best: (id: String, d: CGFloat)?
                for (id, p) in points {
                    let d = hypot(p.x - point.x, p.y - point.y)
                    if d < 80, best == nil || d < best!.d { best = (id, d) }
                }
                if let best { callbacks.onTapCluster(best.id) }
            case .canvas:
                let picked = pickNode(at: point, in: view)
                // Tapping the void deselects (§2.3).
                callbacks.onSelect(picked)
            }
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
            switch gesture.state {
            case .ended, .cancelled, .failed:
                radiant.pinchEnded()
            default:
                radiant.zoom(scale: gesture.scale)
            }
            gesture.scale = 1
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            // Hold-to-mark exists only on the canvas; home holds are the
            // cluster-lift gesture, handled by the SwiftUI overlays.
            guard radiant.currentMode == .canvas else { return }
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
        /// The resolution logic itself is pure (`CanvasPicking.resolve`) and
        /// unit-tested with synthetic candidates (§8).
        private func pickNode(at point: CGPoint, in view: SCNView) -> String? {
            let hits = view.hitTest(
                point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            var projected: [String: CGPoint] = [:]
            for id in radiant.allNodeIds {
                projected[id] = radiant.projectedPoint(of: id, in: view)
            }
            return CanvasPicking.resolve(
                tapPoint: point,
                rayHitIds: hits.compactMap(\.node.name),
                projectedPoints: projected)
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
            ring?.progress = holdIntent == .unmark ? 1 - holdProgress : holdProgress
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
            // Early release: the ring drains fast (~150ms), no haptic thud
            // (notes §3).
            ring?.drain()
            ring = nil
            teardownHold()
            Task { @MainActor in self.holdProgress = 0 }
        }

        private func teardownHold() {
            holdLink?.invalidate()
            holdLink = nil
            holdNodeId = nil
            holdHaptics.end()
            ring?.removeFromSuperlayer()
            ring = nil
        }

        private func addRing(at center: CGPoint, on view: SCNView) {
            // The one shared hold-ring (ux-update §3) — identical everywhere.
            let ring = HoldRingLayer()
            ring.position = center
            ring.progress = holdIntent == .unmark ? 1 : 0
            view.layer.addSublayer(ring)
            self.ring = ring
        }

        private func flashRing() {
            ring?.flash()
            ring = nil
        }

        // MARK: - UI-test hooks overlay (-PRUITestHooks, DEBUG only)

        #if DEBUG
            private var hooksOverlay: UIView?
            private var hooksStateProvider: (@MainActor () -> CanvasHooksState)?
            private var hooksElements: [String: UIView] = [:]
            private var hooksStateView: UIView?
            private var hooksLink: CADisplayLink?

            /// Transparent, non-interactive overlay carrying one accessibility
            /// element per tree node at its projected screen position, plus the
            /// `canvas.state` element. Touches pass through to the SCNView, so
            /// XCUITest taps/holds exercise the real gesture + picking path.
            func installHooksOverlay(
                on view: SCNView, stateProvider: @escaping @MainActor () -> CanvasHooksState
            ) {
                let overlay = UIView(frame: view.bounds)
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.isUserInteractionEnabled = false
                overlay.backgroundColor = .clear
                view.addSubview(overlay)
                hooksOverlay = overlay
                hooksStateProvider = stateProvider

                let stateView = UIView(frame: CGRect(x: 2, y: 120, width: 3, height: 3))
                stateView.isAccessibilityElement = true
                stateView.accessibilityIdentifier = "canvas.state"
                stateView.accessibilityLabel = "canvas state"
                overlay.addSubview(stateView)
                hooksStateView = stateView

                let link = CADisplayLink(target: self, selector: #selector(hooksTick))
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 8, maximum: 15, preferred: 10)
                link.add(to: .main, forMode: .common)
                hooksLink = link
            }

            /// The provider is replaced on every SwiftUI update so hook state
            /// follows the live store across the persistent view's lifetime.
            func updateHooksProvider(_ provider: @escaping @MainActor () -> CanvasHooksState) {
                guard hooksOverlay != nil else { return }
                hooksStateProvider = provider
            }

            /// Invalidates the display link (which retains the coordinator);
            /// called from `dismantleUIView`.
            func teardownHooksOverlay() {
                hooksLink?.invalidate()
                hooksLink = nil
                hooksOverlay?.removeFromSuperview()
                hooksOverlay = nil
                hooksElements = [:]
                hooksStateView = nil
                hooksStateProvider = nil
            }

            @objc private func hooksTick() {
                guard let overlay = hooksOverlay,
                    let view = overlay.superview as? SCNView,
                    let state = hooksStateProvider?()
                else { return }
                hooksStateView?.accessibilityValue = state.stateValue

                // Diff element views against the live node set.
                for (id, element) in hooksElements where state.nodeLabels[id] == nil {
                    element.removeFromSuperview()
                    hooksElements.removeValue(forKey: id)
                }
                for (id, label) in state.nodeLabels {
                    let element: UIView
                    if let existing = hooksElements[id] {
                        element = existing
                    } else {
                        element = UIView()
                        element.isUserInteractionEnabled = false
                        element.isAccessibilityElement = true
                        element.accessibilityIdentifier = "node.\(id)"
                        element.accessibilityTraits = .button
                        overlay.addSubview(element)
                        hooksElements[id] = element
                    }
                    // The node's label rides along as the accessibility label —
                    // the foundation for M4 VoiceOver on nodes (§9).
                    element.accessibilityLabel = label
                    if let center = radiant.projectedPoint(of: id, in: view) {
                        element.isHidden = false
                        element.frame = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
                    } else {
                        element.isHidden = true
                    }
                }
            }
        #endif
    }
}
