import Metal
import PrimeRadiantCore
import SceneKit
import UIKit

/// The single-void world (notes §1): one scene, one camera rig, every
/// scenario's constellation at persistent coordinates on the spherical shell
/// (R = 280 layout units == scene units, see WorldModel), wrapped in the
/// procedural nebula. The constellation home and the scenario canvas are the
/// same scene viewed from the two reference camera states; every transition
/// between them is a continuous ~900ms camera flight — no scene swaps, no
/// crossfades, ever.
///
/// Rendering doctrine (mocks 4/7/10): nodes are small emissive star cores with
/// tight additive halos; chords are thin curved amber filaments; the ignited
/// path is a clean straight gold chord over a soft under-glow. Depth cues in
/// priority order: perspective foreshortening, depth dimming
/// (opacity ∝ clamp(scale^1.9, 0.34, 1)), camera DoF focused at the selection
/// distance, chord widths scaled by endpoint depth means, frame-edge vignette.
///
/// Threading: the graph is built/mutated on the main thread; `advance(at:)`
/// runs on SceneKit's render thread each frame. Shared state is guarded by
/// `lock`.
final class RadiantScene: NSObject, @unchecked Sendable {

    let scene: SCNScene
    let cameraNode = SCNNode()

    private let reduceMotion: Bool
    private let device: MTLDevice?
    private let nebula: Nebula

    enum Mode {
        case home
        case canvas
    }

    // MARK: - Cluster storage

    private struct NodeVisual {
        let container: SCNNode
        let glow: SCNNode
        let core: SCNNode
        let glowMaterial: SCNMaterial
        let coreMaterial: SCNMaterial
    }

    /// One scenario's constellation on the shell.
    private final class Cluster {
        let scenarioId: String
        let anchor: SIMD3<Double>
        var visuals: [String: NodeVisual] = [:]
        /// Filament + under-glow keyed by *child* id.
        var filaments: [String: FilamentGeometry] = [:]
        var underglows: [String: FilamentGeometry] = [:]
        var parentIds: [String: String] = [:]
        var filamentRadii: [String: Float] = [:]
        /// 0 = straight (ignited); otherwise the curved-chord bow.
        var filamentBows: [String: Float] = [:]
        /// Under-glow steady-state transparency (sweeps animate toward it).
        var underglowAlpha: [String: CGFloat] = [:]
        var rootId: String = ""
        /// Tree-local steady-state targets (WorldModel space).
        var localTargets: [String: SIMD3<Double>] = [:]
        /// Reflow interpolation endpoints (world space), owned per cluster.
        var fromPositions: [String: SCNVector3] = [:]
        var targetPositions: [String: SCNVector3] = [:]
        /// Base luminance (resolved scenarios render at 0.42 — notes §4).
        var luminance: CGFloat = 1

        init(scenarioId: String) {
            self.scenarioId = scenarioId
            self.anchor = WorldModel.anchorDirection(ulid: scenarioId)
        }

        func worldTargets() -> [String: SCNVector3] {
            localTargets.mapValues { local in
                let w = WorldModel.worldPosition(local: local, anchor: anchor)
                return SCNVector3(w.x, w.y, w.z)
            }
        }
    }

    private var clusters: [String: Cluster] = [:]

    // MARK: - Shared render-thread state (guard with `lock`)

    private let lock = NSLock()
    private var mode: Mode = .home
    private var focusedClusterId: String?
    private var cameraState = WorldModel.CameraState.home()
    /// In-progress flight: interpolate flightFrom → flightTo over the window.
    private var flightFrom: WorldModel.CameraState?
    private var flightTo: WorldModel.CameraState?
    private var flightStart: TimeInterval?
    private var flightPending = false
    private var flightDuration: TimeInterval = Tokens.Motion.diveFlightSeconds
    private var flightCompletion: (@MainActor @Sendable () -> Void)?
    /// Gentle pan (aim-offset) animation, reflow-synchronized.
    private var aimFrom = SIMD3<Double>.zero
    private var aimTo = SIMD3<Double>.zero
    private var aimStart: TimeInterval?
    private var aimPending = false

    private var reflowStart: TimeInterval?
    private var reflowPending = false

    /// Gold sweep root→node (~350ms selection ignite, ~250ms realize —
    /// notes §3): ordered child-ids of the path chords + the window.
    private var sweepChords: [String] = []
    private var sweepStart: TimeInterval?
    private var sweepPending = false
    private var sweepDuration: TimeInterval = Tokens.Motion.igniteSweepSeconds

    private var lastInteraction: TimeInterval = 0
    private var selectionActive = false
    private var listening = false
    private var lastFrameTime: TimeInterval?
    /// Latch so a single pinch fires at most one mode-change request.
    private var pinchLatched = false

    /// Continuous-zoom mode-change requests (notes §2: pinch-out far enough on
    /// canvas begins the flight home; pinch into a home cluster dives).
    var onZoomOutToHome: (@MainActor () -> Void)?
    var onZoomIntoCluster: (@MainActor (String) -> Void)?

    var viewportAspect: Double = 390.0 / 844.0

    /// The hosting SCNView (set by CanvasView on the main thread) so overlays
    /// can project shell coordinates without owning the view.
    weak var hostView: SCNView?

    /// Vertical FOV. Wider than the old 55°: the raking canvas view needs the
    /// horizontal room for a whole constellation at 0.4R. Tests reference it.
    static let fovDegrees = 62.0

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        self.device = MTLCreateSystemDefaultDevice()
        self.nebula = Nebula(reduceMotion: reduceMotion)
        scene = SCNScene()
        super.init()

        scene.background.contents = TokenColors.void
        // Faint depth fog toward the void, scaled to shell units.
        scene.fogColor = TokenColors.void
        scene.fogStartDistance = CGFloat(1.2 * Tokens.World.shellRadius)
        scene.fogEndDistance = CGFloat(4.5 * Tokens.World.shellRadius)
        scene.fogDensityExponent = 1.6

        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 2600
        camera.fieldOfView = CGFloat(Self.fovDegrees)
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        // Frame-edge vignette (depth cue 5) — the void closes in at the edges.
        camera.vignettingIntensity = 1.0
        camera.vignettingPower = 0.55
        // Gentle bloom keeps star cores hot without washing the void.
        camera.bloomIntensity = 0.72
        camera.bloomThreshold = 0.65
        camera.bloomBlurRadius = 6
        // DoF focused at the selection distance (depth cue 3); the projected-
        // scale threshold (0.88) itself is encoded in WorldModel + tests.
        camera.wantsDepthOfField = true
        camera.fStop = 2.0
        camera.focalBlurSampleCount = 12
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        for layer in nebula.layers {
            scene.rootNode.addChildNode(layer.node)
        }
        if !reduceMotion {
            addMotes()
        }

        applyCameraPose(WorldModel.pose(for: cameraState))
    }

    // MARK: - Home content (all scenarios as shell constellations)

    /// Build/diff a constellation for every scenario. Non-focused clusters are
    /// static (no reflow); the focused one is owned by `setScenario`.
    func setScenarios(_ scenarios: [Scenario]) {
        lock.lock()
        let focused = focusedClusterId
        lock.unlock()

        let liveIds = Set(scenarios.map(\.id))
        for (id, cluster) in clusters where !liveIds.contains(id) {
            removeCluster(cluster)
            lock.lock()
            clusters.removeValue(forKey: id)
            lock.unlock()
        }
        for scenario in scenarios where scenario.id != focused {
            let analytics = TreeAnalytics(
                tree: scenario.tree, realizedPath: scenario.realizedPath,
                unit: scenario.payoffUnit)
            build(
                scenarioId: scenario.id, tree: scenario.tree, analytics: analytics,
                realizedPath: scenario.realizedPath, selectedId: nil,
                unit: scenario.payoffUnit, resolved: scenario.status == .resolved,
                animated: false)
        }
    }

    // MARK: - Focused scenario (canvas mode)

    /// Rebuild/diff the focused scenario's constellation and drive a reflow to
    /// new layout targets. `animated:false` (or Reduce Motion) snaps (§3).
    func setScenario(
        scenarioId: String,
        tree: Node,
        analytics: TreeAnalytics,
        realizedPath: [String],
        selectedId: String?,
        unit: PayoffUnit,
        animated: Bool,
        resolved: Bool = false
    ) {
        lock.lock()
        focusedClusterId = scenarioId
        lock.unlock()
        build(
            scenarioId: scenarioId, tree: tree, analytics: analytics,
            realizedPath: realizedPath, selectedId: selectedId, unit: unit,
            resolved: resolved, animated: animated)
    }

    private func removeCluster(_ cluster: Cluster) {
        for (_, visual) in cluster.visuals { visual.container.removeFromParentNode() }
        for (_, filament) in cluster.filaments { filament.node.removeFromParentNode() }
        for (_, glow) in cluster.underglows { glow.node.removeFromParentNode() }
    }

    private func build(
        scenarioId: String, tree: Node, analytics: TreeAnalytics,
        realizedPath: [String], selectedId: String?, unit: PayoffUnit,
        resolved: Bool, animated: Bool
    ) {
        let cluster = clusters[scenarioId] ?? Cluster(scenarioId: scenarioId)
        lock.lock()
        clusters[scenarioId] = cluster
        lock.unlock()
        cluster.luminance = resolved ? CGFloat(Tokens.World.resolvedClusterLuminance) : 1
        cluster.rootId = tree.id

        // Layout: pure 2D sectors → tree-local 3D (branch roll + shell curvature).
        let layout = RadiantLayout.targets(tree: tree, selectedId: selectedId)
        let locals = WorldModel.treeLocalPositions(
            layout: layout, rootId: tree.id, branchOf: WorldModel.branchMap(tree: tree))
        let liveIds = Set(locals.keys)

        let selectionPath: Set<String> =
            selectedId.flatMap { Tree.path(tree, to: $0).map(Set.init) } ?? []
        let orderedPath: [String] = selectedId.flatMap { Tree.path(tree, to: $0) } ?? []

        lock.lock()

        for (id, visual) in cluster.visuals where !liveIds.contains(id) {
            visual.container.removeFromParentNode()
            cluster.visuals.removeValue(forKey: id)
        }
        for (id, filament) in cluster.filaments where !liveIds.contains(id) {
            filament.node.removeFromParentNode()
            cluster.filaments.removeValue(forKey: id)
            cluster.underglows[id]?.node.removeFromParentNode()
            cluster.underglows.removeValue(forKey: id)
            cluster.parentIds.removeValue(forKey: id)
        }

        cluster.parentIds = [:]
        cluster.localTargets = locals
        buildVisuals(
            cluster: cluster, node: tree, parentId: nil, analytics: analytics,
            realized: Set(realizedPath), selectedId: selectedId, unit: unit,
            selectionPath: selectionPath)

        let isFocused = focusedClusterId == scenarioId
        let targets = cluster.worldTargets()

        if isFocused {
            selectionActive = selectedId != nil
            // Gentle pan: keep the selected node + children in-viewport by
            // panning the aim — never the distance (notes §3 invariant).
            if mode == .canvas {
                let keepIds: [String]
                if let selectedId, let selected = Tree.find(tree, id: selectedId) {
                    keepIds = [selectedId] + (selected.children ?? []).map(\.id)
                } else {
                    keepIds = Array(locals.keys)
                }
                let keep = keepIds.compactMap { locals[$0] }
                if let offset = CameraFit.aimOffset(
                    keep: keep,
                    distance: cameraState.distance,
                    tilt: cameraState.tilt,
                    fovDegrees: Self.fovDegrees,
                    viewportAspect: viewportAspect)
                {
                    if animated && !reduceMotion {
                        aimFrom = cameraState.aimOffset
                        aimTo = offset
                        aimPending = true
                        aimStart = nil
                    } else {
                        cameraState.aimOffset = offset
                        aimFrom = offset
                        aimTo = offset
                        aimPending = false
                    }
                }
            }
            // Gold ignite sweep root→selection, slightly ahead of the reflow.
            if selectedId != nil, animated, !reduceMotion, !orderedPath.isEmpty {
                sweepChords = Array(orderedPath.dropFirst())  // chords keyed by child
                sweepDuration = Tokens.Motion.igniteSweepSeconds
                sweepPending = true
                sweepStart = nil
            } else {
                sweepChords = []
                sweepPending = false
                sweepStart = nil
            }
        }

        if isFocused && animated && !reduceMotion {
            var from: [String: SCNVector3] = [:]
            for (id, visual) in cluster.visuals { from[id] = visual.container.position }
            for (id, _) in targets where from[id] == nil {
                if let parent = cluster.parentIds[id], let p = from[parent] {
                    from[id] = p
                } else {
                    from[id] = targets[id]
                }
            }
            cluster.fromPositions = from
            cluster.targetPositions = targets
            reflowPending = true
            reflowStart = nil
            lock.unlock()
        } else {
            cluster.fromPositions = targets
            cluster.targetPositions = targets
            if isFocused {
                reflowPending = false
                reflowStart = nil
            }
            let pose = WorldModel.pose(for: cameraState)
            lock.unlock()
            applyPositions(cluster: cluster, progress: 1, pose: pose)
        }
    }

    private func buildVisuals(
        cluster: Cluster, node: Node, parentId: String?, analytics: TreeAnalytics,
        realized: Set<String>, selectedId: String?, unit: PayoffUnit,
        selectionPath: Set<String>
    ) {
        let color = RadiantMaterials.nodeColor(for: node, unit: unit)
        let nodeAnalytics = analytics[node.id]
        let cumulative = nodeAnalytics?.cumulativeProbability ?? 1

        let visual: NodeVisual
        if let existing = cluster.visuals[node.id] {
            visual = existing
        } else {
            visual = makeVisual(id: node.id)
            cluster.visuals[node.id] = visual
            scene.rootNode.addChildNode(visual.container)
        }

        // Star scale (mocks 4/10): small emissive cores, ~3–6pt at canvas
        // distance, size still encoding cumulative probability. Tight halo
        // (~8–14pt), a star point — never a glow blob.
        let coreRadius = 0.26 + 0.34 * CGFloat(cumulative)
        (visual.core.geometry as? SCNSphere)?.radius = coreRadius
        let haloSize = 2.0 + 1.8 * CGFloat(cumulative)
        (visual.glow.geometry as? SCNPlane).map {
            $0.width = haloSize
            $0.height = haloSize
        }

        let onSelectionPath = selectionPath.contains(node.id)
        let isGhost = nodeAnalytics?.isGhost ?? false
        let baseColor = onSelectionPath ? TokenColors.ignitedGold : color
        var intensity: CGFloat
        if onSelectionPath {
            intensity = 1.0
        } else if selectedId != nil {
            intensity = 0.3
        } else if isGhost {
            intensity = 0.22
        } else {
            intensity = 0.85
        }
        intensity *= cluster.luminance
        visual.glowMaterial.multiply.contents = baseColor.withAlphaComponent(intensity)
        visual.coreMaterial.emission.contents = baseColor.withAlphaComponent(min(1, intensity + 0.35))

        if let parentId {
            cluster.parentIds[node.id] = parentId
            let filament: FilamentGeometry
            if let existing = cluster.filaments[node.id] {
                filament = existing
            } else {
                filament = FilamentGeometry(device: device, color: TokenColors.filamentAmber)
                cluster.filaments[node.id] = filament
                scene.rootNode.addChildNode(filament.node)
                // Pre-allocated under-glow tube: additive, silent until ignited.
                let glow = FilamentGeometry(device: device, color: TokenColors.ignitedGold)
                glow.setAppearance(probability: 1, color: TokenColors.ignitedGold, opacity: 0)
                cluster.underglows[node.id] = glow
                scene.rootNode.addChildNode(glow.node)
            }
            let onRealizedPath = realized.contains(node.id) && realized.contains(parentId)
            let filamentColor: UIColor
            var opacity: CGFloat
            if onSelectionPath {
                filamentColor = TokenColors.ignitedGold
                opacity = 1
            } else if onRealizedPath {
                // Permanent brighter filament (notes §3); at 42% cluster
                // luminance it reads as a quiet gold seam, not a flare.
                filamentColor = TokenColors.ignitedGold
                opacity = 0.9
            } else if selectedId != nil || isGhost {
                filamentColor = TokenColors.filamentAmber
                opacity = 0.25
            } else {
                filamentColor = TokenColors.filamentAmber
                opacity = 0.7
            }
            opacity *= cluster.luminance
            filament.setAppearance(probability: node.p, color: filamentColor, opacity: opacity)
            let ignited = onSelectionPath || onRealizedPath
            // Thin chords (mock 4): ~1–2pt at canvas distance, width encoding
            // probability; ignited/realized run slightly heavier.
            let emphasis: Float = ignited ? 1.15 : 1.0
            cluster.filamentRadii[node.id] = (0.07 + 0.10 * Float(node.p)) * emphasis
            // Ignited path is a clean *straight* chord (notes §4).
            cluster.filamentBows[node.id] = 0
            // Soft under-glow belongs to the ignited selection only (§4).
            cluster.underglowAlpha[node.id] = onSelectionPath ? 0.10 : 0
            if let glow = cluster.underglows[node.id] {
                glow.setAppearance(
                    probability: 1, color: TokenColors.ignitedGold,
                    opacity: cluster.underglowAlpha[node.id] ?? 0)
            }
        }

        for child in node.children ?? [] {
            buildVisuals(
                cluster: cluster, node: child, parentId: node.id, analytics: analytics,
                realized: realized, selectedId: selectedId, unit: unit,
                selectionPath: selectionPath)
        }
    }

    private func makeVisual(id: String) -> NodeVisual {
        let container = SCNNode()
        container.name = id

        let glowMaterial = RadiantMaterials.glowMaterial(color: TokenColors.filamentAmber)
        let plane = SCNPlane(width: 1, height: 1)
        plane.materials = [glowMaterial]
        let glow = SCNNode(geometry: plane)
        glow.name = id
        glow.constraints = [SCNBillboardConstraint()]
        container.addChildNode(glow)

        let coreMaterial = RadiantMaterials.coreMaterial(color: TokenColors.ignitedGold)
        let sphere = SCNSphere(radius: 0.35)
        sphere.segmentCount = 12
        sphere.materials = [coreMaterial]
        let core = SCNNode(geometry: sphere)
        core.name = id
        container.addChildNode(core)

        return NodeVisual(
            container: container, glow: glow, core: core,
            glowMaterial: glowMaterial, coreMaterial: coreMaterial)
    }

    private func addMotes() {
        let motes = SCNParticleSystem()
        motes.birthRate = 5
        motes.particleLifeSpan = 30
        motes.particleSize = 0.6
        motes.particleSizeVariation = 0.4
        motes.particleVelocity = 1.2
        motes.particleVelocityVariation = 0.8
        motes.emitterShape = SCNSphere(radius: CGFloat(1.1 * Tokens.World.shellRadius))
        motes.particleColor = TokenColors.mote.withAlphaComponent(0.4)
        motes.particleImage = RadiantMaterials.glowTexture
        motes.blendMode = .additive
        motes.spreadingAngle = 180
        let emitter = SCNNode()
        let center = WorldModel.capAxis * Tokens.World.shellRadius
        emitter.position = SCNVector3(center.x, center.y, center.z)
        emitter.addParticleSystem(motes)
        scene.rootNode.addChildNode(emitter)
    }

    // MARK: - Camera flights (notes §3: ~900ms, ease-in-out, no swaps)

    /// Dive from wherever the camera is to the canvas state at the scenario's
    /// shell coordinates. Under Reduce Motion the state changes instantly.
    func flyToCanvas(
        scenarioId: String, completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        lock.lock()
        let cluster = clusters[scenarioId] ?? Cluster(scenarioId: scenarioId)
        clusters[scenarioId] = cluster
        lock.unlock()
        // Aim at the tree's fitted center so arrival matches the idle framing.
        let keep = Array(cluster.localTargets.values)
        let offset =
            keep.isEmpty
            ? SIMD3<Double>.zero
            : CameraFit.aimOffset(
                keep: keep,
                distance: Tokens.World.canvasDistanceFactor * Tokens.World.shellRadius,
                tilt: Tokens.World.canvasTiltRadians,
                fovDegrees: Self.fovDegrees,
                viewportAspect: viewportAspect) ?? .zero
        let target = WorldModel.CameraState.canvas(anchor: cluster.anchor, aimOffset: offset)

        lock.lock()
        mode = .canvas
        focusedClusterId = scenarioId
        beginFlightLocked(to: target, completion: completion)
        lock.unlock()
    }

    /// The reverse flight to the home state. Identical curve (notes §3).
    func flyHome(completion: (@MainActor @Sendable () -> Void)? = nil) {
        lock.lock()
        mode = .home
        focusedClusterId = nil
        selectionActive = false
        beginFlightLocked(to: .home(), completion: completion)
        lock.unlock()
    }

    /// Must hold `lock`.
    private func beginFlightLocked(
        to target: WorldModel.CameraState, completion: (@MainActor @Sendable () -> Void)?
    ) {
        pinchLatched = false
        if reduceMotion {
            cameraState = target
            flightFrom = nil
            flightTo = nil
            flightStart = nil
            flightPending = false
            let pose = WorldModel.pose(for: cameraState)
            applyCameraPose(pose)
            if let completion { Task { @MainActor in completion() } }
            return
        }
        flightFrom = cameraState
        flightTo = target
        flightDuration = Tokens.Motion.diveFlightSeconds
        flightPending = true
        flightStart = nil
        flightCompletion = completion
    }

    var currentMode: Mode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    // MARK: - Interaction hooks (main thread)

    /// Drag swings the camera through the void around the shell (notes §2):
    /// azimuth about the aim point's normal, elevation clamped.
    func orbit(deltaX: Double, deltaY: Double) {
        noteInteraction()
        lock.lock()
        cameraState.yaw += deltaX * 0.004
        cameraState.tilt = max(0.12, min(1.25, cameraState.tilt + deltaY * 0.003))
        lock.unlock()
    }

    /// Continuous pinch zoom (notes §2): far enough out on canvas begins the
    /// flight home; deep enough into a home cluster begins the dive.
    func zoom(scale: Double) {
        noteInteraction()
        let R = Tokens.World.shellRadius
        var requestHome = false
        var diveTarget: String?

        lock.lock()
        let clamped = max(0.18 * R, min(2.2 * R, cameraState.distance / scale))
        cameraState.distance = clamped
        if !pinchLatched && flightTo == nil {
            switch mode {
            case .canvas where clamped > 0.85 * R:
                pinchLatched = true
                requestHome = true
            case .home where clamped < 0.95 * R:
                if let nearest = nearestClusterToViewCenterLocked() {
                    pinchLatched = true
                    diveTarget = nearest
                }
            default:
                break
            }
        }
        lock.unlock()

        if requestHome {
            Task { @MainActor in self.onZoomOutToHome?() }
        } else if let diveTarget {
            Task { @MainActor in self.onZoomIntoCluster?(diveTarget) }
        }
    }

    func pinchEnded() {
        lock.lock()
        pinchLatched = false
        lock.unlock()
    }

    /// Must hold `lock`. Nearest cluster to the view center, in screen space.
    private func nearestClusterToViewCenterLocked() -> String? {
        let pose = WorldModel.pose(for: cameraState)
        var best: (id: String, d: Double)?
        for (id, cluster) in clusters {
            let world = cluster.anchor * Tokens.World.shellRadius
            guard
                let p = WorldModel.project(
                    world, pose: pose, fovDegrees: Self.fovDegrees,
                    viewportAspect: viewportAspect)
            else { continue }
            let d = (p.u * p.u + p.v * p.v).squareRoot()
            if best == nil || d < best!.d { best = (id, d) }
        }
        return best?.id
    }

    func setViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewportAspect = size.width / size.height
    }

    func setListening(_ value: Bool) {
        lock.lock()
        listening = value
        lock.unlock()
    }

    func noteInteraction() {
        lock.lock()
        lastInteraction = lastFrameTime ?? 0
        lock.unlock()
    }

    func projectedPoint(of nodeId: String, in view: SCNView) -> CGPoint? {
        lock.lock()
        let container = focusedClusterId.flatMap { clusters[$0]?.visuals[nodeId]?.container }
        lock.unlock()
        guard let container else { return nil }
        let projected = view.projectPoint(container.worldPosition)
        guard projected.z < 1 else { return nil }
        return CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
    }

    /// Convenience for SwiftUI overlays (labels track clusters per frame).
    func clusterScreenPoints() -> [String: CGPoint] {
        guard let hostView else { return [:] }
        return clusterScreenPoints(in: hostView)
    }

    /// Screen positions of every cluster's shell anchor (home overlays).
    func clusterScreenPoints(in view: SCNView) -> [String: CGPoint] {
        lock.lock()
        let anchors = clusters.mapValues(\.anchor)
        lock.unlock()
        var result: [String: CGPoint] = [:]
        for (id, anchor) in anchors {
            let world = anchor * Tokens.World.shellRadius
            let projected = view.projectPoint(SCNVector3(world.x, world.y, world.z))
            guard projected.z < 1 else { continue }
            result[id] = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        }
        return result
    }

    var allNodeIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return focusedClusterId.flatMap { clusters[$0].map { Array($0.visuals.keys) } } ?? []
    }

    // MARK: - Per-frame drive (render thread, via SCNSceneRendererDelegate)

    func advance(at time: TimeInterval) {
        lock.lock()
        lastFrameTime = time
        if reflowPending {
            reflowPending = false
            reflowStart = time
        }
        if flightPending {
            flightPending = false
            flightStart = time
        }
        if aimPending {
            aimPending = false
            aimStart = time
        }
        if sweepPending {
            sweepPending = false
            sweepStart = time
        }

        // Camera flight (continuous, ease-in-out).
        var completion: (@MainActor @Sendable () -> Void)?
        var flightActive = false
        if let start = flightStart, let from = flightFrom, let to = flightTo {
            let raw = min(1, (time - start) / flightDuration)
            let eased = raw * raw * (3 - 2 * raw)
            cameraState = WorldModel.interpolate(from, to, t: eased)
            aimFrom = cameraState.aimOffset
            aimTo = cameraState.aimOffset
            flightActive = true
            if raw >= 1 {
                flightStart = nil
                flightFrom = nil
                flightTo = nil
                completion = flightCompletion
                flightCompletion = nil
            }
        }

        // Gentle pan, synchronized with the reflow window.
        if let start = aimStart {
            let raw = min(1, (time - start) / Tokens.Layout.reflowDurationSeconds)
            let eased = raw * raw * (3 - 2 * raw)
            cameraState.aimOffset = aimFrom + (aimTo - aimFrom) * eased
            if raw >= 1 { aimStart = nil }
        }

        // Idle >5s with nothing selected: slow ambient drift (notes §3).
        let idleFor = time - lastInteraction
        if !reduceMotion, !selectionActive, flightStart == nil,
            idleFor > Tokens.Layout.idleRotationDelaySeconds
        {
            cameraState.yaw += 0.00008  // a fraction of a degree per second (§3)
        }

        let state = cameraState
        let reflow = reflowStart
        let sweep = sweepStart
        let isListening = listening
        let focused = focusedClusterId.flatMap { clusters[$0] }
        lock.unlock()

        let pose = WorldModel.pose(for: state)
        applyCameraPose(pose)
        nebula.bind(toCameraPosition: pose.position)

        // Reflow: interpolate the focused cluster toward its targets.
        if let start = reflow, let cluster = focused {
            let raw = min(1, (time - start) / Tokens.Layout.reflowDurationSeconds)
            let eased = raw * raw * (3 - 2 * raw)
            applyPositions(cluster: cluster, progress: eased, pose: pose)
            if raw >= 1 {
                lock.lock()
                reflowStart = nil
                lock.unlock()
            }
        } else if flightActive, let cluster = focused {
            // Camera in motion: refresh depth-scaled chord widths.
            applyPositions(cluster: cluster, progress: 1, pose: pose)
        }

        // Gold ignite sweep root→node (leads the reflow, notes §3).
        if let start = sweep {
            advanceSweep(at: time, start: start)
        }

        applyDepthCues(pose: pose)

        // The tree subtly brightens while the radiant listens (§2.3).
        let targetExposure: CGFloat = isListening ? 0.35 : 0
        if let camera = cameraNode.camera, abs(camera.exposureOffset - targetExposure) > 0.01 {
            camera.exposureOffset += (targetExposure - camera.exposureOffset) * 0.08
        }

        if let completion {
            if let cluster = focused {
                applyPositions(cluster: cluster, progress: 1, pose: pose)
            }
            Task { @MainActor in completion() }
        }
    }

    private func applyCameraPose(_ pose: WorldModel.Pose) {
        cameraNode.simdPosition = SIMD3<Float>(
            Float(pose.position.x), Float(pose.position.y), Float(pose.position.z))
        // Build orientation from the pose axes (camera looks down -z).
        let m = simd_double3x3(columns: (pose.right, pose.up, -pose.forward))
        let q = simd_quaternion(m)
        cameraNode.simdOrientation = simd_quatf(
            ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
        // DoF focus follows the aim distance (selection distance on canvas).
        cameraNode.camera?.focusDistance = CGFloat(simd_length(pose.aim - pose.position))
    }

    /// Depth dimming (cue 2): opacity ∝ clamp(scale^1.9, 0.34, 1) with the
    /// projected scale relative to the focus distance. Applied per frame to
    /// every star; cheap (node opacity only, no material churn). Holds `lock`
    /// against concurrent rebuilds of the cluster maps.
    private func applyDepthCues(pose: WorldModel.Pose) {
        let focusDepth = simd_length(pose.aim - pose.position)
        lock.lock()
        defer { lock.unlock() }
        for (_, cluster) in clusters {
            for (_, visual) in cluster.visuals {
                let p = visual.container.simdPosition
                let world = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
                let depth = simd_dot(world - pose.position, pose.forward)
                let scale = WorldModel.projectedScale(depth: depth, focusDepth: focusDepth)
                visual.container.opacity = CGFloat(WorldModel.depthOpacity(projectedScale: scale))
            }
        }
    }

    private func advanceSweep(at time: TimeInterval, start: TimeInterval) {
        lock.lock()
        let chords = sweepChords
        let duration = sweepDuration
        let cluster = focusedClusterId.flatMap { clusters[$0] }
        lock.unlock()
        guard let cluster, !chords.isEmpty else { return }

        let progress = min(1, (time - start) / duration)
        let n = Double(chords.count)
        lock.lock()
        for (index, childId) in chords.enumerated() {
            let local = max(0, min(1, progress * n - Double(index)))
            guard let filament = cluster.filaments[childId] else { continue }
            // Sweep the gold in: transparency rises from the ghost level.
            filament.setAppearance(
                probability: 1, color: TokenColors.ignitedGold,
                opacity: 0.25 + 0.75 * CGFloat(local))
            if let glow = cluster.underglows[childId] {
                glow.setAppearance(
                    probability: 1, color: TokenColors.ignitedGold,
                    opacity: (cluster.underglowAlpha[childId] ?? 0) * CGFloat(local))
            }
        }
        if progress >= 1 {
            sweepStart = nil
            sweepChords = []
        }
        lock.unlock()
    }

    /// Interpolate the focused cluster's nodes toward their targets and re-lay
    /// filament tubes (vertex-buffer writes, no geometry churn — §6 perf).
    /// Chord widths scale with the mean of their endpoints' depth factors
    /// (depth cue 4). Holds `lock` for the whole pass: the render thread walks
    /// the same maps a main-thread rebuild mutates.
    private func applyPositions(cluster: Cluster, progress: Double, pose: WorldModel.Pose) {
        lock.lock()
        defer { lock.unlock() }
        let from = cluster.fromPositions
        let to = cluster.targetPositions

        let focusDepth = simd_length(pose.aim - pose.position)
        let t = Float(progress)
        for (id, visual) in cluster.visuals {
            guard let target = to[id] else { continue }
            let origin = from[id] ?? target
            visual.container.position = SCNVector3(
                origin.x + (target.x - origin.x) * t,
                origin.y + (target.y - origin.y) * t,
                origin.z + (target.z - origin.z) * t)
        }
        for (childId, filament) in cluster.filaments {
            guard
                let parentId = cluster.parentIds[childId],
                let childVisual = cluster.visuals[childId],
                let parentVisual = cluster.visuals[parentId]
            else { continue }
            let a = parentVisual.container.position
            let b = childVisual.container.position
            let widthFactor = Float(
                max(
                    0.55,
                    min(
                        1.25,
                        (depthScale(of: a, pose: pose, focusDepth: focusDepth)
                            + depthScale(of: b, pose: pose, focusDepth: focusDepth)) / 2)))
            let radius = (cluster.filamentRadii[childId] ?? 0.1) * widthFactor
            let bow = cluster.filamentBows[childId] ?? 0
            filament.update(from: a, to: b, radius: radius, bow: bow)
            cluster.underglows[childId]?.update(from: a, to: b, radius: radius * 1.6, bow: bow)
        }
    }

    private func depthScale(
        of position: SCNVector3, pose: WorldModel.Pose, focusDepth: Double
    ) -> Double {
        let world = SIMD3<Double>(Double(position.x), Double(position.y), Double(position.z))
        let depth = simd_dot(world - pose.position, pose.forward)
        return WorldModel.projectedScale(depth: depth, focusDepth: focusDepth)
    }
}
