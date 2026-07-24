import PrimeRadiantCore
import SwiftUI

/// The radically minimal node footer (§2.3): tag + title + one sentence, one EV
/// number, a collapsed distribution, and OPEN IN CHAT. The footer describes;
/// the chat discusses. If a number isn't load-bearing, it isn't on the canvas.
struct NodeFooterView: View {
    let node: Node
    let nodeAnalytics: NodeAnalytics?
    let unit: PayoffUnit
    @Binding var isDistributionExpanded: Bool
    var onOpenChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tag)
                .font(Tokens.Fonts.mono(10, medium: true))
                .tracking(Tokens.Fonts.labelTracking)
                .foregroundStyle(Tokens.Role.edgeNeutral)

            Text(title)
                .font(Tokens.Fonts.display(28))
                .foregroundStyle(Tokens.Role.displayText)
                .lineLimit(2)

            // The node's move — one sentence, nothing else.
            if let move = node.move {
                Text(move)
                    .font(Tokens.Fonts.mono(13))
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.8))
                    .lineLimit(2)
            }

            HStack(spacing: 16) {
                // Live figures condition on realized reality (§4).
                if let evLine = EVFormatter.evLine(liveEV, unit: unit) {
                    Text(evLine)
                        .font(Tokens.Fonts.mono(15, medium: true))
                        .foregroundStyle(Tokens.Role.payoffPositive)
                }

                distributionToggle

                Spacer(minLength: 0)

                // Displaced while the distribution is expanded; returns on collapse.
                if !isDistributionExpanded {
                    openInChatButton
                }
            }

            if isDistributionExpanded {
                DistributionHistogram(
                    bins: bins,
                    caption: caption,
                    onCollapse: { withAnimation(.easeOut(duration: 0.2)) { isDistributionExpanded = false } })
            }
        }
    }

    private var distributionToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isDistributionExpanded.toggle() }
        } label: {
            Text("\(isDistributionExpanded ? "▾" : "▸") DISTRIBUTION")
                .font(Tokens.Fonts.mono(11, medium: true))
                .tracking(Tokens.Fonts.labelTracking)
                .foregroundStyle(Tokens.Role.displayText.opacity(0.55))
        }
        .disabled(bins.isEmpty)
        .opacity(bins.isEmpty ? 0.3 : 1)
    }

    private var openInChatButton: some View {
        Button(action: onOpenChat) {
            Text("OPEN IN CHAT →")
                .font(Tokens.Fonts.mono(12, medium: true))
                .tracking(1.5)
                .foregroundStyle(Tokens.Role.secondaryInfo)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Tokens.Role.secondaryInfo.opacity(0.08))
                        .overlay(
                            Capsule().strokeBorder(
                                Tokens.Role.secondaryInfo.opacity(0.35), lineWidth: 1)))
        }
    }

    private var tag: String {
        if node.isTerminal, let payoff = node.payoff {
            let value = unit.scalar(of: payoff)
            if value > 0 { return "FAVORABLE EXIT" }
            if value < 0 { return "ADVERSE" }
            return "STEADY STATE"
        }
        switch node.actor {
        case .user: return "DECISION"
        case .counterpart: return "RESPONSE"
        case .chance: return "CHANCE"
        }
    }

    private var title: String {
        node.sub.map { "\(node.label) — \($0)" } ?? node.label
    }

    private var liveEV: Double? {
        nodeAnalytics?.conditionedEv ?? nodeAnalytics?.ev
    }

    private var bins: [DistributionBin] {
        guard let nodeAnalytics else { return [] }
        return TreeAnalytics.binned(
            nodeAnalytics.conditionedDistribution,
            maxBins: Tokens.Layout.distributionMaxBins)
    }

    /// The single caption — the only metadata on the expanded footer (§2.3).
    private var caption: String {
        let probability = nodeAnalytics?.conditionedCumulativeProbability ?? 0
        return "\(EVFormatter.percent(probability)) of futures · tap to collapse"
    }
}

/// ≤6-bin payoff histogram colored by outcome class; bars, caption, nothing else.
private struct DistributionHistogram: View {
    let bins: [DistributionBin]
    let caption: String
    var onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(bins.enumerated()), id: \.offset) { _, bin in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: bin.outcomeClass))
                            .frame(height: max(6, 52 * barFraction(bin)))
                        Text(EVFormatter.percent(bin.mass / totalMass))
                            .font(Tokens.Fonts.mono(9))
                            .foregroundStyle(Tokens.Role.displayText.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 70, alignment: .bottom)

            Text(caption)
                .font(Tokens.Fonts.mono(11))
                .foregroundStyle(Tokens.Role.displayText.opacity(0.5))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCollapse)
    }

    private var totalMass: Double {
        max(bins.reduce(0) { $0 + $1.mass }, .leastNonzeroMagnitude)
    }

    private func barFraction(_ bin: DistributionBin) -> Double {
        let peak = bins.map(\.mass).max() ?? 1
        return peak > 0 ? bin.mass / peak : 0
    }

    private func color(for outcomeClass: DistributionBin.OutcomeClass) -> Color {
        switch outcomeClass {
        case .favorable: return Tokens.Role.payoffPositive
        case .steady: return Tokens.Role.terminalFavorable
        case .adverse: return Tokens.Role.terminalAdverse
        }
    }
}
