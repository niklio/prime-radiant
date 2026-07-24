import UIKit

/// All motion respects Reduce Motion (handoff §3): snap transitions, no ambient
/// drift, poster instead of the ignition loop. Low Power Mode also stills the
/// ignition video (§2.1).
@MainActor
enum Motion {
    static var isReduced: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    static var ignitionVideoAllowed: Bool {
        !isReduced && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
