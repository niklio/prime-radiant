import SceneKit
import UIKit

/// The living nebula (notes §1): layered value-noise turbulence composited into
/// textures at init — no image assets — mapped onto three huge spheres that
/// surround the camera. Dark circular rifts are punched into the innermost
/// layer; density varies smoothly (no banding/clipping). Layers ride at
/// 0.15×/0.35×/0.6× of camera motion (bound per frame by RadiantScene) so
/// orbiting reveals volume, and drift glacially — full-texture migration over
/// ~3–5 minutes. Static under Reduce Motion.
///
/// Mood contract (mocks 2/4/10): smoke is dim grey-brown, never brighter than
/// the nodes; the void stays near-black at the frame edges (vignette lives on
/// the camera).
final class Nebula {

    struct Layer {
        let node: SCNNode
        /// Fraction of camera motion this layer shows (apparent parallax).
        let parallaxFactor: Double
    }

    private(set) var layers: [Layer] = []

    /// Sphere radii as factors of R, outermost first. Each must exceed the
    /// camera's maximum excursion times its layer's (1 - parallax) follow gap.
    private static let radiusFactors: [Double] = [5.0, 3.8, 2.8]

    init(reduceMotion: Bool) {
        let R = Tokens.World.shellRadius
        let factors = Tokens.World.nebulaParallaxFactors  // [0.15, 0.35, 0.6]
        // Innermost layer alpha-blends (its rifts occlude outer smoke); outer
        // layers add light only.
        let seeds: [UInt64] = [11, 47, 83]
        for (index, factor) in factors.enumerated() {
            let inner = index == factors.count - 1
            let texture = Self.turbulenceTexture(
                size: 384,
                seed: seeds[index % seeds.count],
                // Outer layers: sparse dim haze. Inner: the visible smokescape
                // with the big occluding rifts.
                alphaScale: inner ? 0.52 : 0.28,
                riftCount: inner ? 4 : 2,
                occludesBehind: inner)

            let sphere = SCNSphere(radius: CGFloat(R * Self.radiusFactors[index]))
            sphere.segmentCount = 48
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.black
            material.emission.contents = texture
            material.cullMode = .front  // render the inside of the sphere
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false
            material.blendMode = inner ? .alpha : .add
            material.transparencyMode = .aOne
            material.isDoubleSided = false
            sphere.materials = [material]

            let node = SCNNode(geometry: sphere)
            node.name = "nebula.\(index)"
            node.renderingOrder = -1000 + index  // farthest first, before content
            node.castsShadow = false
            // Equirect textures pinch at the sphere poles (visible pinwheel +
            // meridian streaks). The camera lives around the +z cap, so park
            // each layer's poles along ±x/±z-tilted axes, staggered per layer.
            node.eulerAngles = SCNVector3(
                Float.pi / 2, 0.6 * Float(index + 1), Float.pi / 5)

            if !reduceMotion {
                // Glacial drift: one slow revolution axis per layer; the
                // visible texture migrates fully over ~nebulaDriftMinutes.
                let period = Tokens.World.nebulaDriftMinutes * 60 * Double(6 + index * 3)
                let axis = simd_normalize(SIMD3<Float>(0.2, 1, 0.35 * Float(index + 1)))
                let spin = SCNAction.repeatForever(
                    SCNAction.rotate(
                        by: .pi * 2,
                        around: SCNVector3(axis.x, axis.y, axis.z),
                        duration: period))
                node.runAction(spin)
            }

            layers.append(Layer(node: node, parallaxFactor: factor))
        }
    }

    /// Parallax binding (called every frame from the render loop): a layer that
    /// follows the camera by (1 - f) of its motion shows f of it on screen.
    func bind(toCameraPosition camera: SIMD3<Double>) {
        for layer in layers {
            let follow = camera * (1 - layer.parallaxFactor)
            layer.node.position = SCNVector3(follow.x, follow.y, follow.z)
        }
    }

    // MARK: - Procedural turbulence

    /// Deterministic value-noise fBm, tinted grey-brown, with huge soft-edged
    /// dark circular rifts. Rendered small (bilinear upscale is the free blur
    /// smoke wants) into a plain RGBA bitmap.
    static func turbulenceTexture(
        size: Int, seed: UInt64, alphaScale: Double, riftCount: Int,
        occludesBehind: Bool = false
    ) -> UIImage {
        var rng = SplitMix64(seed: seed)

        // Value-noise lattice, tileable via wrap-around indexing.
        let lattice = 48
        var grid = [Double](repeating: 0, count: lattice * lattice)
        for i in grid.indices { grid[i] = rng.next01() }

        func latticeNoise(_ x: Double, _ y: Double) -> Double {
            let xi = Int(floor(x))
            let yi = Int(floor(y))
            let tx = smooth(x - floor(x))
            let ty = smooth(y - floor(y))
            func g(_ ix: Int, _ iy: Int) -> Double {
                grid[((iy % lattice + lattice) % lattice) * lattice + ((ix % lattice + lattice) % lattice)]
            }
            let a = g(xi, yi) + (g(xi + 1, yi) - g(xi, yi)) * tx
            let b = g(xi, yi + 1) + (g(xi + 1, yi + 1) - g(xi, yi + 1)) * tx
            return a + (b - a) * ty
        }

        // Rifts: huge dark discs with a soft rim, positions from the rng.
        struct Rift {
            var cx: Double
            var cy: Double
            var radius: Double
        }
        // Texture space wraps the whole sky (360°); the canvas frame sees
        // ~1/6 of it, so a rift radius of ~0.05–0.11 reads as a huge dark
        // circle spanning most of the screen (mocks 2/4).
        var rifts: [Rift] = []
        for _ in 0..<riftCount {
            rifts.append(
                Rift(
                    cx: rng.next01(), cy: rng.next01(),
                    radius: 0.05 + 0.06 * rng.next01()))
        }

        let n = size
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        // Grey-brown smoke tint (dimmer than every node core by construction).
        let tint = (r: 0.72, g: 0.62, b: 0.47)
        for py in 0..<n {
            for px in 0..<n {
                let fx = Double(px) / Double(n)
                let fy = Double(py) / Double(n)
                // 5-octave fBm. Base frequency sized so billows span ~10–20°
                // of sky (several per frame), not continent-sized washes.
                var value = 0.0
                var amplitude = 0.5
                var frequency = 11.0
                for _ in 0..<5 {
                    value += amplitude * latticeNoise(fx * frequency, fy * frequency)
                    amplitude *= 0.5
                    frequency *= 2.1
                }
                // Smooth density shaping: most of the sky stays near-black;
                // only the fBm crests read as billows. Smoothstep, no clipping.
                var density = smooth(max(0, min(1, (value - 0.40) * 2.4)))

                // The rifts: huge near-void discs. They both clear this layer's
                // smoke and (on the alpha-blended inner layer) occlude the
                // outer layers' smoke behind them — the mocks' dark circles.
                // Torus-wrapped distance keeps the sphere seam invisible.
                var riftMask = 0.0
                for rift in rifts {
                    var dx = abs(fx - rift.cx)
                    var dy = abs(fy - rift.cy)
                    dx = min(dx, 1 - dx)
                    dy = min(dy, 1 - dy)
                    let d = (dx * dx + dy * dy).squareRoot() / rift.radius
                    if d < 1 {
                        // Full occlusion in the core, soft rim over the outer half.
                        riftMask = max(riftMask, smooth(max(0, min(1, (1 - d) / 0.5))))
                    }
                }
                density *= (1 - riftMask)

                let smokeAlpha = density * alphaScale
                // Occluding darkness only exists on the inner (alpha) layer;
                // additive layers can't darken, so their rifts just clear smoke.
                let occlusion = occludesBehind ? riftMask * 0.85 : 0
                let alpha = max(smokeAlpha, occlusion)
                let i = (py * n + px) * 4
                // Premultiplied; rift cores hold a whisper of void blue so the
                // circles read as volume, not dead pixels.
                pixels[i] = UInt8(min(255, (tint.r * smokeAlpha + 0.016 * occlusion) * 255))
                pixels[i + 1] = UInt8(min(255, (tint.g * smokeAlpha + 0.016 * occlusion) * 255))
                pixels[i + 2] = UInt8(min(255, (tint.b * smokeAlpha + 0.05 * occlusion) * 255))
                pixels[i + 3] = UInt8(min(255, alpha * 255))
            }
        }

        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)!
        return UIImage(cgImage: image)
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

/// Tiny deterministic RNG for texture generation (never seeded per launch —
/// the nebula must look identical across runs).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next01() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
