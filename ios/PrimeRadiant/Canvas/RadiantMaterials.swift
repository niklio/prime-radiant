import Metal
import PrimeRadiantCore
import SceneKit
import UIKit

/// Programmatic textures + geometry shared by the scenario canvas and the
/// constellation home. No image assets: every glow is generated (handoff §3).
enum RadiantMaterials {

    /// Node color by class (§3 palette): terminals classed by payoff sign
    /// (positive → ignited gold, adverse → ember, steady → outcome blue);
    /// interior nodes are filament amber.
    static func nodeColor(for node: Node, unit: PayoffUnit) -> UIColor {
        guard node.isTerminal else { return TokenColors.filamentAmber }
        guard let payoff = node.payoff else { return TokenColors.filamentAmber }
        let value = unit.scalar(of: payoff)
        if value > 0 { return TokenColors.ignitedGold }
        if value < 0 { return TokenColors.ember }
        return TokenColors.outcomeBlue
    }

    /// White radial gradient on clear, tinted per-node via material multiply.
    /// Star-point falloff (new art direction): a hot pinpoint with a *tight*
    /// halo that dies fast — nodes are small stars, not glow blobs.
    /// Cached — one texture serves every halo sprite in the app.
    static let glowTexture: UIImage = radialGlow(diameter: 128)

    private static func radialGlow(diameter: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
        return renderer.image { context in
            let colors = [
                UIColor(white: 1, alpha: 1).cgColor,
                UIColor(white: 1, alpha: 0.55).cgColor,
                UIColor(white: 1, alpha: 0.10).cgColor,
                UIColor(white: 1, alpha: 0).cgColor,
            ]
            guard
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors as CFArray,
                    locations: [0, 0.10, 0.42, 1])
            else { return }
            let center = CGPoint(x: diameter / 2, y: diameter / 2)
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: diameter / 2,
                options: [])
        }
    }

    /// Additive-blended glow sprite material, tinted `color`.
    static func glowMaterial(color: UIColor, intensity: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.black
        material.emission.contents = glowTexture
        material.multiply.contents = color.withAlphaComponent(intensity)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        return material
    }

    /// Small emissive core material (the bright center under the glow halo).
    static func coreMaterial(color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.emission.contents = color
        material.diffuse.contents = UIColor.black
        return material
    }
}

/// A curved filament between parent and child with **pre-allocated** geometry:
/// the vertex buffer (interleaved position+normal) is an MTLBuffer created once;
/// reflow writes into it in place and SceneKit reads it live via
/// `SCNGeometrySource(buffer:)`. No per-frame geometry reconstruction —
/// handoff §8 performance budget. (CPU fallback rebuilds from Data when no
/// Metal device exists, e.g. the simulator on old hosts.)
final class FilamentGeometry {

    /// Tube tessellation, fixed at init so buffers never resize.
    static let segments = 16
    static let sides = 6
    static var vertexCount: Int { (segments + 1) * sides }

    private static let floatsPerVertex = 6  // position xyz + normal xyz
    private static var stride: Int { floatsPerVertex * MemoryLayout<Float>.size }

    let node: SCNNode
    private let buffer: MTLBuffer?
    private var cpuData: [Float]
    private let material: SCNMaterial

    /// Shared index element — identical for every filament of this tessellation.
    /// Immutable after creation; safe to share across the main + render threads.
    nonisolated(unsafe) private static let sharedElement: SCNGeometryElement = {
        var indices: [UInt16] = []
        indices.reserveCapacity(segments * sides * 6)
        for segment in 0..<segments {
            for side in 0..<sides {
                let a = UInt16(segment * sides + side)
                let b = UInt16(segment * sides + (side + 1) % sides)
                let c = UInt16((segment + 1) * sides + side)
                let d = UInt16((segment + 1) * sides + (side + 1) % sides)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return SCNGeometryElement(indices: indices, primitiveType: .triangles)
    }()

    init(device: MTLDevice?, color: UIColor) {
        let byteCount = Self.vertexCount * Self.stride
        cpuData = [Float](repeating: 0, count: Self.vertexCount * Self.floatsPerVertex)
        buffer = device?.makeBuffer(length: byteCount, options: [.storageModeShared])

        material = SCNMaterial()
        material.lightingModel = .constant
        material.emission.contents = color
        material.diffuse.contents = UIColor.black
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.transparency = 1

        node = SCNNode()
        node.geometry = Self.makeGeometry(buffer: buffer, cpuData: cpuData, material: material)
        node.castsShadow = false
    }

    private static func makeGeometry(
        buffer: MTLBuffer?, cpuData: [Float], material: SCNMaterial
    ) -> SCNGeometry {
        let positionSource: SCNGeometrySource
        let normalSource: SCNGeometrySource
        if let buffer {
            positionSource = SCNGeometrySource(
                buffer: buffer, vertexFormat: .float3, semantic: .vertex,
                vertexCount: vertexCount, dataOffset: 0, dataStride: stride)
            normalSource = SCNGeometrySource(
                buffer: buffer, vertexFormat: .float3, semantic: .normal,
                vertexCount: vertexCount, dataOffset: 3 * MemoryLayout<Float>.size,
                dataStride: stride)
        } else {
            let data = cpuData.withUnsafeBufferPointer { Data(buffer: $0) }
            positionSource = SCNGeometrySource(
                data: data, semantic: .vertex, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: stride)
            normalSource = SCNGeometrySource(
                data: data, semantic: .normal, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 3 * MemoryLayout<Float>.size, dataStride: stride)
        }
        let geometry = SCNGeometry(sources: [positionSource, normalSource], elements: [sharedElement])
        geometry.materials = [material]
        return geometry
    }

    /// Re-lay the tube along a quadratic Bézier `from` → `to`, thickness `radius`.
    /// Writes vertices in place; on the Metal path SceneKit picks the new data up
    /// without any geometry allocation. `bow` curves the chord sideways; the
    /// ignited path passes 0 — a clean straight gold chord (notes §4).
    func update(from start: SCNVector3, to end: SCNVector3, radius: Float, bow bowAmount: Float = 0) {
        let p0 = SIMD3<Float>(start)
        let p2 = SIMD3<Float>(end)
        // Control point bows the filament sideways in the fan plane (§3 curved tubes).
        let mid = (p0 + p2) * 0.5
        let delta = p2 - p0
        let bow = SIMD3<Float>(-delta.y, delta.x, 0) * bowAmount
        let p1 = mid + bow

        let referenceUp = SIMD3<Float>(0, 0, 1)
        var index = 0
        for segment in 0...Self.segments {
            let t = Float(segment) / Float(Self.segments)
            let point = bezier(p0, p1, p2, t)
            var tangent = bezierTangent(p0, p1, p2, t)
            if simd_length(tangent) < 1e-6 { tangent = SIMD3<Float>(0, 1, 0) }
            tangent = simd_normalize(tangent)
            var side = simd_cross(tangent, referenceUp)
            if simd_length(side) < 1e-6 { side = SIMD3<Float>(1, 0, 0) }
            side = simd_normalize(side)
            let up = simd_normalize(simd_cross(side, tangent))

            for sideIndex in 0..<Self.sides {
                let angle = Float(sideIndex) / Float(Self.sides) * 2 * .pi
                let normal = side * cos(angle) + up * sin(angle)
                let vertex = point + normal * radius
                cpuData[index] = vertex.x
                cpuData[index + 1] = vertex.y
                cpuData[index + 2] = vertex.z
                cpuData[index + 3] = normal.x
                cpuData[index + 4] = normal.y
                cpuData[index + 5] = normal.z
                index += 6
            }
        }

        if let buffer {
            cpuData.withUnsafeBytes { bytes in
                buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        } else {
            // CPU fallback: geometry rebuild (reflow-only, never steady-state).
            node.geometry = Self.makeGeometry(buffer: nil, cpuData: cpuData, material: material)
        }
    }

    /// Probability → visual weight: thickness and opacity both encode `p` (§3).
    func setAppearance(probability: Double, color: UIColor, opacity: CGFloat) {
        material.emission.contents = color
        material.transparency = opacity * (0.35 + 0.65 * CGFloat(probability))
    }

    private func bezier(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let u = 1 - t
        return p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t)
    }

    private func bezierTangent(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        (p1 - p0) * (2 * (1 - t)) + (p2 - p1) * (2 * t)
    }
}

extension SIMD3<Float> {
    init(_ v: SCNVector3) { self.init(Float(v.x), Float(v.y), Float(v.z)) }
}
