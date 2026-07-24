import Foundation
import PrimeRadiantCore

/// One-number EV display, `EV ≈ +$12k` style (handoff §2.3). Display-only —
/// the underlying values come straight from PrimeRadiantCore analytics.
enum EVFormatter {

    /// `EV ≈ +$12k` / `EV ≈ −14 utils`. Nil when the subtree carries no payoffs
    /// (numbers are honest or absent — handoff §1 principle 2).
    static func evLine(_ value: Double?, unit: PayoffUnit) -> String? {
        guard let value else { return nil }
        return "EV ≈ \(compact(value, unit: unit, signed: true))"
    }

    static func compact(_ value: Double, unit: PayoffUnit, signed: Bool) -> String {
        let sign = value < 0 ? "−" : (signed && value > 0 ? "+" : "")
        let magnitude = abs(value)
        switch unit.kind {
        case .currency:
            // Sample units are commonly "thousands" scenarios; abbreviate large
            // magnitudes, keep small ones plain: 12000 → $12k, 12 → $12.
            if magnitude >= 1000 {
                return "\(sign)$\(trimmed(magnitude / 1000))k"
            }
            let suffix = unit.label.lowercased().contains("k") ? "k" : ""
            return "\(sign)$\(trimmed(magnitude))\(suffix)"
        case .utils:
            return "\(sign)\(trimmed(magnitude)) utils"
        case .scale:
            return "\(sign)\(trimmed(magnitude))"
        }
    }

    static func percent(_ probability: Double) -> String {
        "\(Int((probability * 100).rounded()))%"
    }

    private static func trimmed(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
