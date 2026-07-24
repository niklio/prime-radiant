import UIKit

/// Rising haptic ramp for the hold-to-mark gesture (handoff §2.3): light pulses
/// that intensify with ring progress, a confirming thud at completion.
@MainActor
final class HapticRamp {
    private let pulse = UIImpactFeedbackGenerator(style: .light)
    private let impact = UIImpactFeedbackGenerator(style: .heavy)
    private var lastStep = -1

    func begin() {
        lastStep = -1
        pulse.prepare()
        impact.prepare()
    }

    /// Pulse at rising intensity on each fifth of progress.
    func update(progress: Double) {
        let step = Int(progress * 5)
        guard step != lastStep, step < 5 else { return }
        lastStep = step
        pulse.impactOccurred(intensity: 0.3 + 0.14 * CGFloat(step))
    }

    func thud() {
        impact.impactOccurred(intensity: 1)
    }

    func end() {
        lastStep = -1
    }
}

/// One-off haptic accents.
@MainActor
enum Haptics {
    static func lift() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func settle() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
    }
}
