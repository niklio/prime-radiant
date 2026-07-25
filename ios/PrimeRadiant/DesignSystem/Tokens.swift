import SwiftUI

/// The Radiant look, mirrored from `shared/tokens.json` — that file is the source of
/// truth (handoff §3, §3.1). Build against these tokens, never literals; a repaint is
/// a one-file change here plus a mock regeneration there. Values must not drift.
enum Tokens {

    // MARK: - Color (shared/tokens.json → color)

    enum Palette {
        /// Deep blue-black, never pure black.
        static let void = Color(hex: 0x050510)
        /// Neutral edges / decision nodes.
        static let filamentAmber = Color(hex: 0xE8A33D)
        /// Selected path, positive payoffs.
        static let ignitedGold = Color(hex: 0xFFD98A)
        /// Favorable/steady terminal class.
        static let outcomeBlue = Color(hex: 0x6DB8FF)
        /// Adverse terminal class.
        static let ember = Color(hex: 0xFF6B5E)
        /// Hover / secondary info / listening accent.
        static let whisperCyan = Color(hex: 0x9FE8FF)
        /// Display text.
        static let parchment = Color(hex: 0xF3ECD8)
        /// Drifting background motes.
        static let mote = Color(hex: 0x9FB4E8)
    }

    /// Semantic roles (shared/tokens.json → colorRoles).
    enum Role {
        static let background = Palette.void
        static let edgeNeutral = Palette.filamentAmber
        static let decisionNode = Palette.filamentAmber
        static let selectedPath = Palette.ignitedGold
        static let payoffPositive = Palette.ignitedGold
        static let terminalFavorable = Palette.outcomeBlue
        static let terminalAdverse = Palette.ember
        static let hover = Palette.whisperCyan
        static let secondaryInfo = Palette.whisperCyan
        static let displayText = Palette.parchment
        static let listeningAccent = Palette.whisperCyan
    }

    // MARK: - Type (shared/tokens.json → type)

    /// Display: Cormorant Garamond — node titles and rare display moments only.
    /// Data/UI: IBM Plex Mono 300/500 — all probabilities, labels, buttons, transcript.
    /// Nothing else (handoff §3).
    ///
    /// TODO: vend the OFL font files into PrimeRadiant/Resources/Fonts/ (names must
    /// match project.yml UIAppFonts). Until then these resolve to system fallbacks.
    enum Fonts {
        static let displayLightName = "CormorantGaramond-Light"
        static let displaySemiboldName = "CormorantGaramond-SemiBold"
        static let monoLightName = "IBMPlexMono-Light"
        static let monoMediumName = "IBMPlexMono-Medium"

        /// Until the OFL binaries are vended, fall back to the same built-in
        /// faces the mocks render with (Georgia serif / Menlo mono) instead of
        /// the SF system font — the chrome's mono/serif hierarchy is part of
        /// the mock contract (`.custom` alone would silently fall back to SF).
        private static func available(_ name: String) -> Bool {
            UIFont(name: name, size: 12) != nil
        }

        static func display(_ size: CGFloat, semibold: Bool = false) -> Font {
            let name = semibold ? displaySemiboldName : displayLightName
            return .custom(available(name) ? name : "Georgia", size: size)
        }

        static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
            let name = medium ? monoMediumName : monoLightName
            return .custom(available(name) ? name : "Menlo", size: size)
        }

        /// Generous letterspacing for mono labels (handoff §3: labels track wide).
        static let labelTracking: CGFloat = 2.5
    }

    // MARK: - Layout (shared/tokens.json → layout)

    enum Layout {
        static let minChildSectorFraction = 0.09
        static let onPathChildWeight = 3.2
        static let offPathSiblingWeight = 0.5
        static let reflowDurationSeconds = 1.0
        static let markHoldDurationSeconds = 0.7
        static let idleRotationDelaySeconds = 5.0
        static let chatSurfaceTreeOpacity = 0.15
        static let chatSurfacePatchTreeOpacity = 0.35
        static let distributionMaxBins = 6
    }

    // MARK: - World (shared/tokens.json → world; notes §1)

    /// Single-void world model: one scene, one camera, all content at persistent
    /// coordinates on a spherical shell. Scene-unit scale: 1 SceneKit scene unit
    /// == 1 layout unit (R = 280 keeps every coordinate well inside Float
    /// precision; the camera's zFar is sized to cover the nebula spheres).
    enum World {
        static let shellRadius = 280.0
        /// Camera distance from the aimed shell point, as factors of R.
        static let homeDistanceFactor = 1.5
        static let homeTiltRadians = 0.22
        static let canvasDistanceFactor = 0.4
        static let canvasTiltRadians = 0.58

        /// Depth cues (notes §1, priority order).
        static let nearFarSizeRatio = 1.4
        static let minAssertedSizeRatio = 1.3
        static let dimmingExponent = 1.9
        static let dimmingFloor = 0.34
        static let dofBlurBelowProjectedScale = 0.88

        static let nebulaParallaxFactors = [0.15, 0.35, 0.6]
        static let nebulaDriftMinutes = 4.0
        static let resolvedClusterLuminance = 0.42
    }

    // MARK: - Motion (shared/tokens.json → motion; notes §3 — targets, not laws)

    enum Motion {
        /// Selection reflow window [min, max]; the scene uses the tokens' layout
        /// reflowDurationSeconds (1.0) which sits inside it.
        static let reflowSeconds = 0.9...1.1
        static let igniteSweepSeconds = 0.35
        static let markRingSeconds = 0.7
        static let markCancelDrainSeconds = 0.15
        static let realizeSweepSeconds = 0.25
        static let ghostDownSeconds = 0.4
        static let evTickSeconds = 0.3
        static let diveFlightSeconds = 0.9
        static let chatEnterSeconds = 0.35
        static let chatSettleSeconds = 0.6
        static let peekReturnTravelFraction = 0.4
        static let peekSnapBackSeconds = 0.25
        static let ridgeExpandSeconds = 0.3
        static let ridgeDrawSeconds = 0.4
        static let ridgeCollapseSeconds = 0.2
        static let voicePulsePeriodSeconds = 1.6
        static let voiceTreeBrighten = 0.15
        static let composerCompressSeconds = 0.2
        static let unbornPulsePeriodSeconds = 2.4
        static let unbornPulseGlowDelta = 0.2

        // Onboarding + creation (ux-update doc §1–§3; not yet in tokens.json).
        /// Birth hold is deliberately longer than the 700ms mark so the two
        /// can't collide in muscle memory (ux-update §3).
        static let birthHoldSeconds = 0.9
        /// Unborn node dissolves back into cloud when nothing is said (§2).
        static let birthDissolveSeconds = 0.45
        /// Existing constellations dim to ~60% during the birth hold (§2).
        static let birthDimLevel = 0.6
        /// Address-probe node pulse (~1/s — no spinner exists in this app, §1).
        static let probePulsePeriodSeconds = 1.0
        /// Unreachable line fade-in (§1, 1b2).
        static let unreachableFadeSeconds = 0.4
        /// Paired rings expand over ~700ms (§1, 1d).
        static let pairedRingsSeconds = 0.7
    }
}

extension Color {
    /// Exact-hex construction so token values match shared/tokens.json bit-for-bit.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0)
    }
}

#if canImport(UIKit)
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0)
    }
}

/// UIKit-side mirror for SceneKit materials (SCNMaterial wants UIColor).
enum TokenColors {
    static let void = UIColor(hex: 0x050510)
    static let filamentAmber = UIColor(hex: 0xE8A33D)
    static let ignitedGold = UIColor(hex: 0xFFD98A)
    static let outcomeBlue = UIColor(hex: 0x6DB8FF)
    static let ember = UIColor(hex: 0xFF6B5E)
    static let whisperCyan = UIColor(hex: 0x9FE8FF)
    static let parchment = UIColor(hex: 0xF3ECD8)
    static let mote = UIColor(hex: 0x9FB4E8)
}
#endif
