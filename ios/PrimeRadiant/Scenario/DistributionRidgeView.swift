import PrimeRadiantCore
import SwiftUI

/// The luminous ridge (mock 6): a smooth area curve of the payoff distribution
/// inside the capsule — gold rim line, gradient fill fading down, a dotted
/// vertical meanline labeled `μ +$12k`, an etched tick axis beneath with mono
/// payoff labels, and the single caption (`31% of futures`). Expand ~300ms,
/// the curve draws left→right ~400ms, μ fades last; collapse ~200ms (tokens
/// motion). The axis is the only place graduation ticks exist (notes §4).
struct DistributionRidgeView: View {
    let points: [DistributionPoint]
    let mean: Double?
    let unit: PayoffUnit
    let caption: String

    /// Curve draw-on progress (left→right trim).
    @State private var drawn = false
    /// μ meanline + label fade, after the draw.
    @State private var meanVisible = false

    private var domain: ClosedRange<Double> {
        let payoffs = points.map(\.payoff)
        guard let low = payoffs.min(), let high = payoffs.max() else { return 0...1 }
        // Wide enough that the kernel density tapers to ~zero at both edges.
        let pad = max((high - low) * 0.32, max(abs(high), 1) * 0.08)
        return (low - pad)...(high + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    ridge(in: size)
                    if let mean {
                        meanline(mean, in: size)
                    }
                }
            }
            .frame(height: 96)

            axis
                .padding(.top, 2)

            Text(caption)
                .font(Tokens.Fonts.mono(10))
                .tracking(0.8)
                .foregroundStyle(Tokens.Role.displayText.opacity(0.45))
                .padding(.top, 6)
                .accessibilityIdentifier("capsule.ridge.caption")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capsule.ridge")
        .onAppear {
            guard !Motion.isReduced else {
                drawn = true
                meanVisible = true
                return
            }
            withAnimation(.easeOut(duration: Tokens.Motion.ridgeDrawSeconds)) {
                drawn = true
            }
            withAnimation(
                .easeIn(duration: 0.25).delay(Tokens.Motion.ridgeDrawSeconds)
            ) {
                meanVisible = true
            }
        }
    }

    // MARK: - Curve

    /// Curve top: μ label band (16pt) stays clear of the ridge crest.
    private static let labelBand: CGFloat = 18

    private func ridge(in size: CGSize) -> some View {
        let shape = RidgeShape(samples: samples)
        let rect = CGRect(
            x: 0, y: Self.labelBand, width: size.width, height: size.height - Self.labelBand)
        return ZStack {
            // Gradient fill rising beneath the rim as it draws.
            RidgeAreaShape(samples: samples)
                .fill(
                    LinearGradient(
                        colors: [
                            Tokens.Role.selectedPath.opacity(0.45),
                            Tokens.Role.selectedPath.opacity(0.04),
                        ],
                        startPoint: .top, endPoint: .bottom))
                .opacity(drawn ? 1 : 0)
            // Gold rim, drawn left→right.
            shape
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(
                    Tokens.Role.selectedPath,
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .shadow(color: Tokens.Role.selectedPath.opacity(0.6), radius: 3)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(y: Self.labelBand)
    }

    /// Kernel-smoothed density over the padded payoff domain, normalized to 1.
    private var samples: [CGFloat] {
        let count = 72
        let low = domain.lowerBound
        let high = domain.upperBound
        let span = max(high - low, .leastNonzeroMagnitude)
        let sigma = max(span / 9, .leastNonzeroMagnitude)
        var values = (0..<count).map { index -> Double in
            let x = low + span * Double(index) / Double(count - 1)
            return points.reduce(0) { sum, point in
                let z = (x - point.payoff) / sigma
                return sum + point.mass * exp(-0.5 * z * z)
            }
        }
        let peak = values.max() ?? 1
        if peak > 0 { values = values.map { $0 / peak } }
        return values.map { CGFloat($0) }
    }

    // MARK: - Meanline

    private func meanline(_ mean: Double, in size: CGSize) -> some View {
        let x = xPosition(of: mean, width: size.width)
        let label = "μ \(EVFormatter.compact(mean, unit: unit, signed: true))"
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: Self.labelBand + 2))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(
                Tokens.Role.selectedPath.opacity(0.85),
                style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            Text(label)
                .font(Tokens.Fonts.mono(10))
                .tracking(0.5)
                .foregroundStyle(Tokens.Role.selectedPath)
                .fixedSize()
                .position(x: min(max(x, 30), size.width - 30), y: 6)
                .accessibilityIdentifier("capsule.ridge.mean")
        }
        .opacity(meanVisible ? 1 : 0)
    }

    // MARK: - Axis (ticks + mono payoff labels, derived from the range)

    private var axis: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                // Axis hairline with a tick at every label.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: width, y: 0.5))
                    for value in tickValues {
                        let x = xPosition(of: value, width: width)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: 4))
                    }
                }
                .stroke(Tokens.Role.edgeNeutral.opacity(0.55), lineWidth: 1)

                ForEach(tickValues, id: \.self) { value in
                    Text(EVFormatter.compact(value, unit: unit, signed: true))
                        .font(Tokens.Fonts.mono(10))
                        .foregroundStyle(Tokens.Role.selectedPath.opacity(0.9))
                        .fixedSize()
                        .position(x: xPosition(of: value, width: width), y: 13)
                }
            }
        }
        .frame(height: 20)
    }

    /// Tick values across the distribution: the distinct payoffs themselves
    /// when there are 3–6 of them (the mock's non-uniform `+$22k` tail), else
    /// nice uniform steps over the range.
    private var tickValues: [Double] {
        let distinct = Array(Set(points.map(\.payoff))).sorted()
        guard let low = distinct.first, let high = distinct.last else { return [] }
        if (3...6).contains(distinct.count) { return distinct }
        if distinct.count < 3 {
            let range = high - low
            guard range > 0 else { return distinct }
            let step = niceStep(range / 4)
            var ticks: [Double] = []
            var value = (low / step).rounded(.up) * step
            while value <= high + step * 0.01 {
                ticks.append(value)
                value += step
            }
            return ticks.isEmpty ? distinct : ticks
        }
        // >6 distinct payoffs: 5 nice uniform steps.
        let step = niceStep((high - low) / 4)
        var ticks: [Double] = []
        var value = (low / step).rounded(.up) * step
        while value <= high + step * 0.01 {
            ticks.append(value)
            value += step
        }
        return ticks
    }

    private func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let fraction = raw / magnitude
        let nice: Double =
            fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10
        return nice * magnitude
    }

    private func xPosition(of value: Double, width: CGFloat) -> CGFloat {
        let low = domain.lowerBound
        let span = max(domain.upperBound - low, .leastNonzeroMagnitude)
        return CGFloat((value - low) / span) * width
    }
}

/// The rim: an open path along the smoothed density curve (trimmable so it
/// draws left→right).
private struct RidgeShape: Shape {
    let samples: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        let step = rect.width / CGFloat(samples.count - 1)
        for (index, sample) in samples.enumerated() {
            let point = CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - sample * rect.height * 0.94)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The same curve closed down to the baseline, for the gradient fill.
private struct RidgeAreaShape: Shape {
    let samples: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = RidgeShape(samples: samples).path(in: rect)
        guard !path.isEmpty else { return path }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
