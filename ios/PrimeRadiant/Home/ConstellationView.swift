import PrimeRadiantCore
import SceneKit
import SwiftUI

/// The constellation is the only home (§2.2): every scenario is a mini-tree
/// cluster floating in the shared void, rendered from its real stored tree,
/// sized by recent activity, serif-labeled with a status glyph line. There is
/// no list view. Tap dives; hold-and-drag lifts a cluster toward the
/// ARCHIVE / DELETE wells; `+` creates from anywhere.
struct ConstellationView: View {
    let scenarios: [Scenario]
    let archivedCount: Int
    var onOpen: (String) -> Void
    var onCreate: () -> Void
    var onArchive: (String) -> Void
    var onDelete: (String) -> Void
    var onUndoDelete: (String) -> Void

    @State private var controller = ConstellationController()
    @State private var screenPositions: [String: CGPoint] = [:]
    /// Cluster currently lifted under the finger (hold-and-drag management).
    @State private var lifted: (id: String, offset: CGSize)?
    @State private var undoToastId: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ConstellationSceneView(controller: controller) {
                    reproject()
                }
                .ignoresSafeArea()

                if scenarios.isEmpty {
                    EmptyConstellation(onCreate: onCreate)
                } else {
                    clusterOverlays
                }

                topBar
                if archivedCount > 0 {
                    archivedEdge
                }
                if lifted != nil {
                    wells(in: geometry.size)
                }
                if let undoId = undoToastId {
                    undoToast(for: undoId)
                }
            }
        }
        .background(Tokens.Role.background)
        .statusBarHidden()
        .onAppear { controller.rebuild(scenarios: scenarios) }
        .onChange(of: scenarios.map(\.updatedAt)) {
            controller.rebuild(scenarios: scenarios)
            reproject()
        }
    }

    private func reproject() {
        screenPositions = controller.projectAll()
    }

    // MARK: - Overlays

    private var topBar: some View {
        VStack {
            HStack {
                Text("YOUR FUTURES")
                    .font(Tokens.Fonts.mono(12, medium: true))
                    .tracking(Tokens.Fonts.labelTracking)
                    .foregroundStyle(Tokens.Role.edgeNeutral)
                Spacer()
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Tokens.Role.displayText)
                }
                .accessibilityLabel("begin a scenario")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var clusterOverlays: some View {
        ForEach(scenarios) { scenario in
            if let position = screenPositions[scenario.id] {
                ClusterLabel(
                    scenario: scenario,
                    lifted: lifted?.id == scenario.id)
                    .position(position)
                    .offset(lifted?.id == scenario.id ? lifted!.offset : .zero)
                    .gesture(clusterGesture(for: scenario, at: position))
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    /// Tap dives; hold lifts (haptic) and drags toward the wells (§2.2).
    private func clusterGesture(for scenario: Scenario, at position: CGPoint) -> some Gesture {
        let tap = TapGesture().onEnded {
            controller.dive(to: scenario.id, reduceMotion: Motion.isReduced) {
                onOpen(scenario.id)
            }
        }
        let holdDrag = LongPressGesture(minimumDuration: 0.35)
            .onEnded { _ in
                Haptics.lift()
                lifted = (scenario.id, .zero)
            }
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    lifted = (scenario.id, drag.translation)
                }
            }
            .onEnded { value in
                defer { lifted = nil }
                guard case .second(true, let drag?) = value else { return }
                let dropPoint = CGPoint(
                    x: position.x + drag.translation.width,
                    y: position.y + drag.translation.height)
                handleDrop(of: scenario.id, at: dropPoint)
            }
        return tap.exclusively(before: holdDrag)
    }

    private func handleDrop(of id: String, at point: CGPoint) {
        guard let well = WellsLayout.well(containing: point, in: UIScreen.main.bounds.size)
        else {
            Haptics.settle()  // released anywhere else: settles back
            return
        }
        switch well {
        case .archive:
            onArchive(id)
        case .delete:
            // Soft-delete server-side, 30-day purge, single undo toast (§2.2).
            onDelete(id)
            undoToastId = id
        }
    }

    private func wells(in size: CGSize) -> some View {
        HStack(spacing: 18) {
            WellView(label: "ARCHIVE", color: Tokens.Role.secondaryInfo)
            WellView(label: "DELETE", color: Tokens.Role.terminalAdverse)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 36)
        .transition(.opacity)
    }

    private func undoToast(for id: String) -> some View {
        VStack {
            Spacer()
            Button {
                onUndoDelete(id)
                undoToastId = nil
            } label: {
                Text("deleted · undo")
                    .font(Tokens.Fonts.mono(12))
                    .foregroundStyle(Tokens.Role.displayText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Tokens.Palette.void.opacity(0.92)))
                    .overlay(Capsule().strokeBorder(Tokens.Role.displayText.opacity(0.25), lineWidth: 1))
            }
            .padding(.bottom, 24)
            .task {
                try? await Task.sleep(for: .seconds(5))
                undoToastId = nil
            }
        }
    }

    /// Archived scenarios collapse into a dim cluster at the constellation's far
    /// edge (§2.2). M3: pinching into it reveals them; for now it only glows.
    private var archivedEdge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("· archived \(archivedCount)")
                    .font(Tokens.Fonts.mono(10))
                    .tracking(1.5)
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.25))
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Wells

private enum WellsLayout {
    enum Well { case archive, delete }

    /// Two drop targets along the bottom edge; geometry mirrored in WellView.
    static func well(containing point: CGPoint, in size: CGSize) -> Well? {
        guard point.y > size.height - 140 else { return nil }
        return point.x < size.width / 2 ? .archive : .delete
    }
}

private struct WellView: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(Tokens.Fonts.mono(11, medium: true))
            .tracking(Tokens.Fonts.labelTracking)
            .foregroundStyle(color)
            .frame(width: 140, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

// MARK: - Cluster label (serif + status glyph line, §2.2)

private struct ClusterLabel: View {
    let scenario: Scenario
    let lifted: Bool

    var body: some View {
        VStack(spacing: 3) {
            // Invisible hit area over the cluster itself.
            Color.clear
                .frame(width: 96, height: 84)
                .contentShape(Rectangle())
            Text(scenario.title)
                .font(Tokens.Fonts.display(20))
                .foregroundStyle(Tokens.Role.displayText)
                .lineLimit(1)
            Text(statusLine)
                .font(Tokens.Fonts.mono(11))
                .tracking(1.5)
                .foregroundStyle(statusColor.opacity(0.85))
        }
        .scaleEffect(lifted ? 1.08 : 1)
        .shadow(color: lifted ? Tokens.Role.selectedPath.opacity(0.4) : .clear, radius: 12)
        .animation(.easeOut(duration: 0.2), value: lifted)
    }

    private var statusLine: String {
        switch scenario.status {
        case .modeling:
            return "○ modeling · \(recency)"
        case .in_progress:
            return "◐ in progress · \(recency)"
        case .resolved:
            // Resolved clusters carry their outcome, e.g. "+$8k vs est." (§2.2).
            if let actual = scenario.resolvedPayoff {
                let estimate = TreeAnalytics(
                    tree: scenario.tree, realizedPath: scenario.realizedPath,
                    unit: scenario.payoffUnit)[scenario.tree.id]?.ev ?? 0
                let delta = EVFormatter.compact(
                    actual - estimate, unit: scenario.payoffUnit, signed: true)
                return "● resolved · \(delta) vs est."
            }
            return "● resolved"
        }
    }

    private var statusColor: Color {
        switch scenario.status {
        case .modeling: return Tokens.Role.displayText
        case .in_progress: return Tokens.Role.edgeNeutral
        case .resolved: return Tokens.Role.terminalFavorable
        }
    }

    private var recency: String {
        let interval = Date().timeIntervalSince(scenario.updatedAt)
        if interval < 3600 { return "\(max(1, Int(interval / 60)))m" }
        if interval < 86_400 { return "\(Int(interval / 3600))h" }
        if interval < 172_800 { return "yesterday" }
        return "\(Int(interval / 86_400))d"
    }
}

// MARK: - Empty state: one pulsing unborn node (§2.2)

private struct EmptyConstellation: View {
    var onCreate: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Tokens.Role.selectedPath, .clear],
                        center: .center, startRadius: 2, endRadius: 34))
                .frame(width: 68, height: 68)
                .scaleEffect(pulse ? 1.18 : 0.92)
                .animation(
                    Motion.isReduced
                        ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                    value: pulse)
            Text("begin a scenario")
                .font(Tokens.Fonts.mono(13))
                .tracking(1.5)
                .foregroundStyle(Tokens.Role.displayText.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCreate)
        .onAppear { pulse = true }
    }
}

// MARK: - SceneKit constellation

/// Owns the shared void scene: one mini tree per scenario built from its real
/// stored tree via RadiantLayout, connective dust, and the dive camera move —
/// the cluster grows into the full canvas in one continuous zoom (§2.2).
@MainActor
final class ConstellationController {
    let scene: SCNScene
    let cameraNode: SCNNode
    private var anchors: [String: SCNVector3] = [:]
    private var clusterNodes: [String: SCNNode] = [:]
    weak var scnView: SCNView?

    private static let restCameraPosition = SCNVector3(0, 0, 11)

    init() {
        scene = SCNScene()
        scene.background.contents = TokenColors.void
        scene.fogColor = TokenColors.void
        scene.fogStartDistance = 10
        scene.fogEndDistance = 26

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 60
        cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = Self.restCameraPosition
        scene.rootNode.addChildNode(cameraNode)

        if !Motion.isReduced {
            addDust()
        }
    }

    func rebuild(scenarios: [Scenario]) {
        for (_, node) in clusterNodes { node.removeFromParentNode() }
        clusterNodes = [:]
        anchors = [:]

        for (index, scenario) in scenarios.enumerated() {
            let anchor = Self.anchor(index: index)
            anchors[scenario.id] = anchor
            let cluster = buildCluster(for: scenario, activityScale: activityScale(scenario))
            cluster.position = anchor
            scene.rootNode.addChildNode(cluster)
            clusterNodes[scenario.id] = cluster
        }
        cameraNode.position = Self.restCameraPosition
    }

    /// Deterministic staggered field (golden-angle spiral) — stable across runs.
    private static func anchor(index: Int) -> SCNVector3 {
        let i = Double(index)
        let radius = 1.5 * (i + 1).squareRoot()
        let angle = i * 2.399963  // golden angle
        return SCNVector3(
            Float(radius * cos(angle) * 0.75),
            Float(radius * sin(angle)),
            0)
    }

    /// Sized by recent activity (§2.2): fresher scenarios render larger.
    private func activityScale(_ scenario: Scenario) -> Float {
        let days = Date().timeIntervalSince(scenario.updatedAt) / 86_400
        return Float(max(0.6, 1.0 - days * 0.05))
    }

    private func buildCluster(for scenario: Scenario, activityScale: Float) -> SCNNode {
        let container = SCNNode()
        container.name = scenario.id
        let miniScale: Float = 0.22 * activityScale
        let layout = RadiantLayout.targets(tree: scenario.tree, selectedId: nil)
        let unit = scenario.payoffUnit

        var positions: [String: SCNVector3] = [:]
        Tree.forEach(scenario.tree) { node in
            guard let target = layout[node.id] else { return }
            let position = SCNVector3(
                Float(target.x) * miniScale,
                Float(target.y) * miniScale,
                Float(target.z) * miniScale)
            positions[node.id] = position

            let material = RadiantMaterials.glowMaterial(
                color: RadiantMaterials.nodeColor(for: node, unit: unit), intensity: 0.9)
            let size = CGFloat(0.14 * activityScale)
            let plane = SCNPlane(width: size, height: size)
            plane.materials = [material]
            let sprite = SCNNode(geometry: plane)
            sprite.position = position
            sprite.constraints = [SCNBillboardConstraint()]
            container.addChildNode(sprite)
        }

        Tree.forEach(scenario.tree) { node in
            for child in node.children ?? [] {
                guard let from = positions[node.id], let to = positions[child.id] else { continue }
                let filament = FilamentGeometry(
                    device: MTLCreateSystemDefaultDevice(), color: TokenColors.filamentAmber)
                filament.setAppearance(probability: child.p, color: TokenColors.filamentAmber, opacity: 0.55)
                filament.update(from: from, to: to, radius: 0.006)
                container.addChildNode(filament.node)
            }
        }
        return container
    }

    private func addDust() {
        let dust = SCNParticleSystem()
        dust.birthRate = 4
        dust.particleLifeSpan = 24
        dust.particleSize = 0.015
        dust.particleVelocity = 0.03
        dust.emitterShape = SCNSphere(radius: 8)
        dust.particleColor = TokenColors.mote.withAlphaComponent(0.4)
        dust.particleImage = RadiantMaterials.glowTexture
        dust.blendMode = .additive
        scene.rootNode.addChildNode({
            let node = SCNNode()
            node.addParticleSystem(dust)
            return node
        }())
    }

    /// Screen positions for the SwiftUI label/gesture overlays (camera is static
    /// outside the dive, so projection is computed on rebuild/resize, not per frame).
    func projectAll() -> [String: CGPoint] {
        guard let view = scnView else { return [:] }
        var result: [String: CGPoint] = [:]
        for (id, anchor) in anchors {
            let projected = view.projectPoint(anchor)
            guard projected.z < 1 else { continue }
            result[id] = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        }
        return result
    }

    /// The app's second signature moment (§2.2): the camera dives and the cluster
    /// grows into the full scenario canvas in one continuous zoom. The scenario
    /// canvas fades in over the final frames of this move.
    func dive(to id: String, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard let anchor = anchors[id], !reduceMotion else {
            completion()
            return
        }
        let target = SCNVector3(anchor.x, anchor.y, anchor.z + 1.4)
        let move = SCNAction.move(to: target, duration: 0.55)
        move.timingMode = .easeInEaseOut
        cameraNode.runAction(move) {
            Task { @MainActor in
                completion()
                // Reset for the return trip home.
                self.cameraNode.position = Self.restCameraPosition
            }
        }
    }
}

private struct ConstellationSceneView: UIViewRepresentable {
    let controller: ConstellationController
    var onReady: () -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = controller.scene
        view.pointOfView = controller.cameraNode
        view.backgroundColor = UIColor(hex: 0x050510)
        view.rendersContinuously = true
        view.isUserInteractionEnabled = false  // gestures live on the SwiftUI overlays
        controller.scnView = view
        Task { @MainActor in onReady() }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
