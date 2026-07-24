import SwiftUI

/// Bottom-left legend, shown only when nothing is selected (§2.3 — selecting a
/// node replaces it with the footer). Rows mirror mock 4-canvas-idle.
struct LegendView: View {
    private static let rows: [(color: Color, label: String)] = [
        (Tokens.Role.payoffPositive, "FAVORABLE EXIT"),
        (Tokens.Role.terminalFavorable, "STEADY STATE"),
        (Tokens.Role.terminalAdverse, "ADVERSE"),
        (Tokens.Role.decisionNode, "DECISION"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.rows, id: \.label) { row in
                HStack(spacing: 10) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 9, height: 9)
                        .shadow(color: row.color.opacity(0.8), radius: 4)
                    Text(row.label)
                        .font(Tokens.Fonts.mono(11, medium: true))
                        .tracking(Tokens.Fonts.labelTracking)
                        .foregroundStyle(Tokens.Role.displayText.opacity(0.75))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("canvas.legend")
    }
}
