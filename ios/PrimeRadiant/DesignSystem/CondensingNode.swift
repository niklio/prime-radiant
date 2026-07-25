import SwiftUI
import UIKit

/// The unborn node condensing beneath a birth hold (ux-update §2, mock 10b):
/// glow gathering out of the nebula — the same birth motif as the empty home
/// and the provisioning screen. Screen-space layer while the finger is down;
/// on completion the scene's shell-anchored unborn star takes over.
@MainActor
final class CondensingNodeLayer: CALayer {

    private let glow = CAGradientLayer()
    private let core = CALayer()

    /// Non-override initializer keeps MainActor isolation (CALayer.init() is
    /// nonisolated — same pattern as HoldRingLayer).
    init(initialProgress: Double = 0) {
        super.init()
        glow.type = .radial
        glow.colors = [
            UIColor.white.withAlphaComponent(0.95).cgColor,
            TokenColors.ignitedGold.withAlphaComponent(0.55).cgColor,
            TokenColors.ignitedGold.withAlphaComponent(0).cgColor,
        ]
        glow.locations = [0, 0.3, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        let glowSize: CGFloat = 44
        glow.frame = CGRect(
            x: -glowSize / 2, y: -glowSize / 2, width: glowSize, height: glowSize)
        glow.cornerRadius = glowSize / 2
        addSublayer(glow)

        let coreSize: CGFloat = 5
        core.frame = CGRect(
            x: -coreSize / 2, y: -coreSize / 2, width: coreSize, height: coreSize)
        core.cornerRadius = coreSize / 2
        core.backgroundColor = UIColor.white.cgColor
        addSublayer(core)

        actions = ["opacity": NSNull(), "transform": NSNull()]
        glow.actions = ["opacity": NSNull(), "transform": NSNull()]
        core.actions = ["opacity": NSNull(), "transform": NSNull()]
        progress = initialProgress
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 0…1 with the ring fill: the glow gathers — brightens and grows.
    var progress: Double = 0 {
        didSet {
            let clamped = CGFloat(min(1, max(0, progress)))
            opacity = Float(0.15 + 0.85 * clamped)
            let scale = 0.45 + 0.55 * clamped
            setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
    }

    /// Early release: dissolve back into cloud (~450ms), then gone.
    func dissolve() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        fade.duration = Tokens.Motion.birthDissolveSeconds
        opacity = 0
        add(fade, forKey: "dissolve")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Tokens.Motion.birthDissolveSeconds
        ) { [weak self] in
            self?.removeFromSuperlayer()
        }
    }
}

/// SwiftUI wrapper for the frozen `-PRDebugBirth` capture state.
struct CondensingNodeView: UIViewRepresentable {
    var progress: Double

    final class Host: UIView {
        let node = CondensingNodeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(node)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            node.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ view: Host, context: Context) {
        view.node.progress = progress
    }
}
