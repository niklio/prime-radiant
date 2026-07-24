import Foundation

/// One (payoff, mass) atom of a node's outcome distribution. Exact — binning is display-only.
public struct DistributionPoint: Equatable, Sendable {
    public var payoff: Double
    public var mass: Double
    public init(payoff: Double, mass: Double) {
        self.payoff = payoff
        self.mass = mass
    }
}

/// A display bin for the footer histogram (≤6 bins, handoff §2.3).
public struct DistributionBin: Equatable, Sendable {
    public enum OutcomeClass: Sendable { case adverse, steady, favorable }
    public var lowerBound: Double
    public var upperBound: Double
    public var mass: Double
    public var outcomeClass: OutcomeClass
    public init(lowerBound: Double, upperBound: Double, mass: Double, outcomeClass: OutcomeClass) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.mass = mass
        self.outcomeClass = outcomeClass
    }
}

/// Everything computed client-side, never model-supplied (handoff §4).
public struct NodeAnalytics: Equatable, Sendable {
    /// Product of raw sibling-renormalized probabilities root→node.
    public var cumulativeProbability: Double
    /// Cumulative probability under conditioning on the realized path
    /// (reached sibling → 1, others → 0 at each realized node).
    public var conditionedCumulativeProbability: Double
    /// Probability-weighted payoff over subtree terminals that carry payoffs,
    /// normalized to the payoff-carrying mass. Nil when no terminal has a payoff.
    public var ev: Double?
    /// EV under conditioning on the realized path.
    public var conditionedEv: Double?
    /// Fraction of the subtree's probability mass whose terminals carry payoffs (coarseness signal).
    public var payoffCoverage: Double
    /// Exact outcome distribution (raw probabilities), sorted by payoff.
    public var distribution: [DistributionPoint]
    /// Exact outcome distribution under conditioning.
    public var conditionedDistribution: [DistributionPoint]
    /// Best/worst terminal payoff bounds over the subtree (raw, ignoring probability).
    public var bestTerminal: Double?
    public var worstTerminal: Double?
    /// True when the node is on the realized path or is the reached sibling's descendant frontier.
    public var isGhost: Bool
}

/// Full-tree analytics, computed in one pass from (tree, realizedPath, unit).
public struct TreeAnalytics: Sendable {
    public let byId: [String: NodeAnalytics]
    public let rootId: String

    public subscript(id: String) -> NodeAnalytics? { byId[id] }

    public init(tree: Node, realizedPath: [String], unit: PayoffUnit) {
        // Work on the renormalized tree so `p` is trustworthy regardless of input drift.
        let root = Tree.renormalized(tree)
        let realized = Set(realizedPath)
        // Conditioning: at each node ON the realized path that has a realized child,
        // that child's effective p is 1 and its siblings' 0. Below the deepest realized
        // node (and everywhere off-path), raw probabilities apply.
        var accumulator: [String: NodeAnalytics] = [:]

        func visit(
            _ node: Node, cumulative: Double, conditionedCumulative: Double, ghost: Bool
        ) -> (dist: [DistributionPoint], conditionedDist: [DistributionPoint], coveredMass: Double, totalMass: Double) {
            var distribution: [DistributionPoint] = []
            var conditionedDistribution: [DistributionPoint] = []
            var coveredMass = 0.0
            var totalMass = 0.0
            var best: Double? = nil
            var worst: Double? = nil

            if node.isTerminal {
                totalMass = 1
                if let payoff = node.payoff {
                    let value = unit.scalar(of: payoff)
                    distribution = [DistributionPoint(payoff: value, mass: 1)]
                    conditionedDistribution = distribution
                    coveredMass = 1
                    best = value
                    worst = value
                }
            } else {
                let children = node.children ?? []
                let realizedChildId = children.first(where: { realized.contains($0.id) })?.id
                // Conditioning applies at this node only if the node itself is realized
                // and one of its children is realized too.
                let conditionsHere = realized.contains(node.id) && realizedChildId != nil
                for child in children {
                    let conditionedP: Double =
                        conditionsHere ? (child.id == realizedChildId ? 1 : 0) : child.p
                    let childGhost = ghost || (conditionsHere && child.id != realizedChildId)
                    let sub = visit(
                        child,
                        cumulative: cumulative * child.p,
                        conditionedCumulative: conditionedCumulative * conditionedP,
                        ghost: childGhost)
                    for point in sub.dist {
                        distribution.append(DistributionPoint(payoff: point.payoff, mass: point.mass * child.p))
                    }
                    for point in sub.conditionedDist {
                        let mass = point.mass * conditionedP
                        if mass > 0 {
                            conditionedDistribution.append(DistributionPoint(payoff: point.payoff, mass: mass))
                        }
                    }
                    coveredMass += sub.coveredMass * child.p
                    totalMass += sub.totalMass * child.p
                    if let childBest = accumulator[child.id]?.bestTerminal {
                        best = best.map { Swift.max($0, childBest) } ?? childBest
                    }
                    if let childWorst = accumulator[child.id]?.worstTerminal {
                        worst = worst.map { Swift.min($0, childWorst) } ?? childWorst
                    }
                }
            }

            distribution = Self.merged(distribution)
            conditionedDistribution = Self.merged(conditionedDistribution)

            let ev = Self.expectedValue(of: distribution)
            let conditionedEv = Self.expectedValue(of: conditionedDistribution)

            accumulator[node.id] = NodeAnalytics(
                cumulativeProbability: cumulative,
                conditionedCumulativeProbability: conditionedCumulative,
                ev: ev,
                conditionedEv: conditionedEv,
                payoffCoverage: totalMass > 0 ? coveredMass / totalMass : 0,
                distribution: distribution,
                conditionedDistribution: conditionedDistribution,
                bestTerminal: best,
                worstTerminal: worst,
                isGhost: ghost)
            return (distribution, conditionedDistribution, coveredMass, totalMass)
        }

        _ = visit(root, cumulative: 1, conditionedCumulative: 1, ghost: false)
        self.byId = accumulator
        self.rootId = root.id
    }

    /// Exact merge of equal payoffs, sorted ascending.
    static func merged(_ points: [DistributionPoint]) -> [DistributionPoint] {
        guard !points.isEmpty else { return [] }
        var byPayoff: [Double: Double] = [:]
        for point in points { byPayoff[point.payoff, default: 0] += point.mass }
        return byPayoff.map { DistributionPoint(payoff: $0.key, mass: $0.value) }
            .sorted { $0.payoff < $1.payoff }
    }

    /// Mean over the payoff-carrying mass (normalized), nil for an empty distribution.
    static func expectedValue(of points: [DistributionPoint]) -> Double? {
        let mass = points.reduce(0) { $0 + $1.mass }
        guard mass > 0 else { return nil }
        return points.reduce(0) { $0 + $1.payoff * $1.mass } / mass
    }

    /// Bin an exact distribution for the footer histogram: ≤`maxBins` equal-width bins,
    /// classed adverse (<0), steady (=0 boundary handled by sign of bin center), favorable (>0).
    public static func binned(_ points: [DistributionPoint], maxBins: Int = 6) -> [DistributionBin] {
        guard !points.isEmpty, maxBins > 0 else { return [] }
        let payoffs = points.map(\.payoff)
        guard let low = payoffs.min(), let high = payoffs.max() else { return [] }
        if low == high || points.count <= maxBins {
            // One bin per distinct payoff.
            return points.map {
                DistributionBin(
                    lowerBound: $0.payoff, upperBound: $0.payoff, mass: $0.mass,
                    outcomeClass: Self.outcomeClass(of: $0.payoff))
            }
        }
        let width = (high - low) / Double(maxBins)
        var bins = (0..<maxBins).map { index in
            DistributionBin(
                lowerBound: low + Double(index) * width,
                upperBound: low + Double(index + 1) * width,
                mass: 0,
                outcomeClass: .steady)
        }
        for point in points {
            let index = Swift.min(maxBins - 1, Int((point.payoff - low) / width))
            bins[index].mass += point.mass
        }
        for index in bins.indices {
            let center = (bins[index].lowerBound + bins[index].upperBound) / 2
            bins[index].outcomeClass = Self.outcomeClass(of: center)
        }
        return bins.filter { $0.mass > 0 }
    }

    static func outcomeClass(of payoff: Double) -> DistributionBin.OutcomeClass {
        if payoff < 0 { return .adverse }
        if payoff > 0 { return .favorable }
        return .steady
    }
}
