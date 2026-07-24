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

        static func display(_ size: CGFloat, semibold: Bool = false) -> Font {
            .custom(semibold ? displaySemiboldName : displayLightName, size: size)
        }

        static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
            .custom(medium ? monoMediumName : monoLightName, size: size)
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
        static let distributionMaxBins = 6
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
