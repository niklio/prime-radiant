import Metal
import PrimeRadiantCore
import SceneKit
import UIKit

/// SceneKit scene for one scenario tree: additive glow sprites over emissive cores,
/// curved tube filaments encoding probability, motes + depth fog, ignited-chain vs
/// ghosted-field selection, ~1s eased reflow, idle ambient rotation (handoff §3).
///
/// Threading: the scene graph is built/mutated on the main thread; `advance(at:)`
/// runs on SceneKit's render thread each frame (legal inside the renderer delegate).
/// The small shared reflow/interaction state is guarded by `lock`.
final class RadiantScene: NSObject, @unchecked Sendable {

    let scene: SCNScene
    /// Yaw rig (drag-orbit) → pitch rig → camera.
    private let yawRig = SCNNode()
    private let pitchRig = SCNNode()
    let cameraNode = SCNNode()

    private let reduceMotion: Bool
    private let device: MTLDevice?

    private struct NodeVisual {
        let container: SCNNode
        let glow: SCNNode
        let core: SCNNode
        let glowMaterial: SCNMaterial
        let coreMaterial: SCNMaterial
    }

    private var visuals: [String: NodeVisual] = [:]
    /// Filament keyed by *child* id; every non-root node has exactly one.
    private var filaments: [String: FilamentGeometry] = [:]
    private var parentIds: [String: String] = [:]
    private var filamentRadii: [String: Float] = [:]

    // Shared with the render thread — guard with `lock`.
    private let lock = NSLock()
    private var fromPositions: [String: SCNVector3] = [:]
    private var targetPositions: [String: SCNVector3] = [:]
    private var reflowStart: TimeInterval?
    private var reflowPending = false
    private var lastInteraction: TimeInterval = 0
    private var selectionActive = false
    private var listening = false
    private var lastFrameTime: TimeInterval?

    private var cameraDistance: Double = 7.5

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        self.device = MTLCreateSystemDefaultDevice()
        scene = SCNScene()
        super.init()

        scene.background.contents = TokenColors.void
        // Subtle depth fog toward the void (§3).
        scene.fogColor = TokenColors.void
        scene.fogStartDistance = 8
        scene.fogEndDistance = 22
        scene.fogDensityExponent = 1.5

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 60
        camera.fieldOfView = 55
        camera.wantsHDR = true  // exposureOffset drives the listening brighten
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Float(cameraDistance))
        // Root at bottom-center of the frame: aim slightly above the root.
        pitchRig.position = SCNVector3(0, 1.7, 0)
        pitchRig.addChildNode(cameraNode)
        yawRig.addChildNode(pitchRig)
        scene.rootNode.addChildNode(yawRig)

        if !reduceMotion {
            addMotes()
        }
    }

    // MARK: - Content

    /// Rebuild/diff visuals for the given tree and drive a reflow to new layout
    /// targets. `animated:false` (or Reduce Motion) snaps instantly (§3).
    func setScenario(
        tree: Node,
        analytics: TreeAnalytics,
        realizedPath: [String],
        selectedId: String?,
        unit: PayoffUnit,
        animated: Bool
    ) {
        let layout = RadiantLayout.targets(tree: tree, selectedId: selectedId)
        let liveIds = Set(layout.keys)

        // The lock covers the visuals/filament maps for the whole rebuild: the
        // render thread walks the same maps in applyPositions each frame.
        lock.lock()

        // Remove visuals for nodes no longer in the tree.
        for (id, visual) in visuals where !liveIds.contains(id) {
            visual.container.removeFromParentNode()
            visuals.removeValue(forKey: id)
        }
        for (id, filament) in filaments where !liveIds.contains(id) {
            filament.node.removeFromParentNode()
            filaments.removeValue(forKey: id)
            parentIds.removeValue(forKey: id)
        }

        // Build/refresh visuals and appearance.
        parentIds = [:]
        buildVisuals(
            node: tree, parentId: nil, analytics: analytics,
            realized: Set(realizedPath), selectedId: selectedId, unit: unit,
            selectionPath: selectedId.flatMap { Tree.path(tree, to: $0).map(Set.init) } ?? [])

        // Reflow targets.
        let targets = layout.mapValues { SCNVector3($0.x, $0.y, $0.z) }
        selectionActive = selectedId != nil
        if animated && !reduceMotion {
            fromPositions = visuals.mapValues { $0.container.position }
            // New nodes grow out of their parent's current position.
            for (id, _) in targets where fromPositions[id] == nil {
                if let parent = parentIds[id], let parentPosition = fromPositions[parent] {
                    fromPositions[id] = parentPosition
                } else {
                    fromPositions[id] = targets[id]
                }
            }
            targetPositions = targets
            reflowPending = true
            reflowStart = nil
        } else {
            fromPositions = targets
            targetPositions = targets
            reflowPending = false
            reflowStart = nil
            lock.unlock()
            applyPositions(progress: 1)
            return
        }
        lock.unlock()
    }

    private func buildVisuals(
        node: Node, parentId: String?, analytics: TreeAnalytics,
        realized: Set<String>, selectedId: String?, unit: PayoffUnit,
        selectionPath: Set<String>
    ) {
        let color = RadiantMaterials.nodeColor(for: node, unit: unit)
        let nodeAnalytics = analytics[node.id]
        let cumulative = nodeAnalytics?.cumulativeProbability ?? 1

        let visual: NodeVisual
        if let existing = visuals[node.id] {
            visual = existing
        } else {
            visual = makeVisual(id: node.id)
            visuals[node.id] = visual
            scene.rootNode.addChildNode(visual.container)
        }

        // Node glow size encodes cumulative probability (§3).
        let glowSize = CGFloat(0.55 + 0.85 * cumulative)
        (visual.glow.geometry as? SCNPlane).map {
            $0.width = glowSize
            $0.height = glowSize
        }
        (visual.core.geometry as? SCNSphere)?.radius = 0.035 + 0.05 * CGFloat(cumulative)

        // Selection: ignited chain vs ghosted field; marked-ghost branches stay dim.
        let onSelectionPath = selectionPath.contains(node.id)
        let isGhost = nodeAnalytics?.isGhost ?? false
        let baseColor = onSelectionPath ? TokenColors.ignitedGold : color
        let intensity: CGFloat
        if onSelectionPath {
            intensity = 1.0
        } else if selectedId != nil {
            intensity = 0.3  // ghosted field behind an ignited chain
        } else if isGhost {
            intensity = 0.22  // unrealized sibling of a marked branch
        } else {
            intensity = 0.85
        }
        visual.glowMaterial.multiply.contents = baseColor.withAlphaComponent(intensity)
        visual.coreMaterial.emission.contents = baseColor.withAlphaComponent(min(1, intensity + 0.15))

        // Filament from parent.
        if let parentId {
            parentIds[node.id] = parentId
            let filament: FilamentGeometry
            if let existing = filaments[node.id] {
                filament = existing
            } else {
                filament = FilamentGeometry(device: device, color: TokenColors.filamentAmber)
                filaments[node.id] = filament
                scene.rootNode.addChildNode(filament.node)
            }
            let onRealizedPath = realized.contains(node.id) && realized.contains(parentId)
            let filamentColor: UIColor
            let opacity: CGFloat
            if onSelectionPath {
                filamentColor = TokenColors.ignitedGold
                opacity = 1
            } else if onRealizedPath {
                // The realized path stays permanently brighter (§2.3).
                filamentColor = TokenColors.ignitedGold
                opacity = 0.9
            } else if selectedId != nil || isGhost {
                filamentColor = TokenColors.filamentAmber
                opacity = 0.25
            } else {
                filamentColor = TokenColors.filamentAmber
                opacity = 0.7
            }
            filament.setAppearance(probability: node.p, color: filamentColor, opacity: opacity)
            // Thickness encodes probability; ignited/realized run thicker (§3).
            let emphasis: Float = (onSelectionPath || onRealizedPath) ? 1.6 : 1.0
            filamentRadii[node.id] = (0.012 + 0.03 * Float(node.p)) * emphasis
        }

        for child in node.children ?? [] {
            buildVisuals(
                node: child, parentId: node.id, analytics: analytics,
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
        glow.name = id  // hit tests resolve to the node id
        glow.constraints = [SCNBillboardConstraint()]
        container.addChildNode(glow)

        let coreMaterial = RadiantMaterials.coreMaterial(color: TokenColors.ignitedGold)
        let sphere = SCNSphere(radius: 0.05)
        sphere.segmentCount = 16
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
        motes.birthRate = 6
        motes.particleLifeSpan = 20
        motes.particleSize = 0.02
        motes.particleSizeVariation = 0.015
        motes.particleVelocity = 0.05
        motes.particleVelocityVariation = 0.04
        motes.emitterShape = SCNSphere(radius: 9)
        motes.particleColor = TokenColors.mote.withAlphaComponent(0.5)
        motes.particleImage = RadiantMaterials.glowTexture
        motes.blendMode = .additive
        motes.spreadingAngle = 180
        let emitter = SCNNode()
        emitter.position = SCNVector3(0, 2, 0)
        emitter.addParticleSystem(motes)
        scene.rootNode.addChildNode(emitter)
    }

    // MARK: - Interaction hooks (main thread)

    func orbit(deltaX: Double, deltaY: Double) {
        noteInteraction()
        yawRig.eulerAngles.y += Float(deltaX) * 0.005
        let pitch = pitchRig.eulerAngles.x - Float(deltaY) * 0.004
        pitchRig.eulerAngles.x = max(-0.55, min(0.35, pitch))
    }

    func zoom(scale: Double) {
        noteInteraction()
        cameraDistance = max(3, min(16, cameraDistance / scale))
        cameraNode.position.z = Float(cameraDistance)
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
        guard let container = visuals[nodeId]?.container else { return nil }
        let projected = view.projectPoint(container.worldPosition)
        guard projected.z < 1 else { return nil }
        return CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
    }

    var allNodeIds: [String] { Array(visuals.keys) }

    // MARK: - Per-frame drive (render thread, via SCNSceneRendererDelegate)

    func advance(at time: TimeInterval) {
        lock.lock()
        lastFrameTime = time
        if reflowPending {
            reflowPending = false
            reflowStart = time
        }
        let start = reflowStart
        let idleFor = time - lastInteraction
        let selection = selectionActive
        let isListening = listening
        lock.unlock()

        if let start {
            let raw = min(1, (time - start) / Tokens.Layout.reflowDurationSeconds)
            // Smoothstep ease over ~1s (§3).
            let eased = raw * raw * (3 - 2 * raw)
            applyPositions(progress: eased)
            if raw >= 1 {
                lock.lock()
                reflowStart = nil
                lock.unlock()
            }
        }

        // Idle >5s with nothing selected: slow ambient rotation (§3).
        if !reduceMotion, !selection, idleFor > Tokens.Layout.idleRotationDelaySeconds {
            yawRig.eulerAngles.y += 0.0007
        }

        // The tree subtly brightens while the radiant listens (§2.3).
        let targetExposure: CGFloat = isListening ? 0.35 : 0
        if let camera = cameraNode.camera, abs(camera.exposureOffset - targetExposure) > 0.01 {
            camera.exposureOffset += (targetExposure - camera.exposureOffset) * 0.08
        }
    }

    /// Interpolate every node toward its target and re-lay filament tubes through
    /// the transition (vertex-buffer writes, no geometry churn — §8).
    private func applyPositions(progress: Double) {
        lock.lock()
        defer { lock.unlock() }
        let from = fromPositions
        let to = targetPositions

        let t = Float(progress)
        for (id, visual) in visuals {
            guard let target = to[id] else { continue }
            let origin = from[id] ?? target
            visual.container.position = SCNVector3(
                origin.x + (target.x - origin.x) * t,
                origin.y + (target.y - origin.y) * t,
                origin.z + (target.z - origin.z) * t)
        }
        for (childId, filament) in filaments {
            guard
                let parentId = parentIds[childId],
                let childVisual = visuals[childId],
                let parentVisual = visuals[parentId]
            else { continue }
            filament.update(
                from: parentVisual.container.position,
                to: childVisual.container.position,
                radius: filamentRadii[childId] ?? 0.02)
        }
    }
}
