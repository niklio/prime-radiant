import Foundation

/// Backward-induction policy annotation (handoff §4).
/// At `user` nodes the max-EV child is marked optimal. At `counterpart` nodes two modes:
/// listed-`p` weighting, or "assume the counterpart optimizes their stated payoffs" when
/// counterpart payoffs are modeled as a named component. At `chance` nodes, listed `p` always.
public enum CounterpartMode: Equatable, Sendable {
    /// Weight counterpart branches by their elicited probabilities.
    case listedProbabilities
    /// The counterpart deterministically picks the child maximizing the named payoff
    /// component (their stated payoff). Falls back to listed probabilities in any
    /// subtree where that component is absent from every terminal.
    case optimizesOwnPayoff(component: String)
}

public struct PolicyAnnotation: Equatable, Sendable {
    /// The policy value of the node under backward induction (user's weighted scalar).
    /// Nil when no payoff information exists in the subtree.
    public var value: Double?
    /// For `user` nodes: the max-EV child id. For `counterpart` nodes in
    /// optimizing mode: the child the counterpart picks. Nil otherwise.
    public var optimalChildId: String?
    /// Whether optimizing-counterpart mode actually drove this node's value
    /// (differs per subtree under the fallback rule).
    public var usedCounterpartOptimization: Bool
}

public struct PolicyAnalysis: Sendable {
    public let byId: [String: PolicyAnnotation]
    public let mode: CounterpartMode

    public subscript(id: String) -> PolicyAnnotation? { byId[id] }

    private struct SubtreeValue {
        var child: Node
        var user: Double?
        var counterpart: Double?
        var usedOpt: Bool
    }

    public init(tree: Node, unit: PayoffUnit, mode: CounterpartMode = .listedProbabilities) {
        let root = Tree.renormalized(tree)
        self.mode = mode
        var accumulator: [String: PolicyAnnotation] = [:]

        func probabilityWeighted(_ results: [SubtreeValue], _ value: (SubtreeValue) -> Double?) -> Double? {
            var weighted = 0.0
            var mass = 0.0
            for result in results {
                guard let v = value(result) else { continue }
                weighted += v * result.child.p
                mass += result.child.p
            }
            return mass > 0 ? weighted / mass : nil
        }

        func bestBy(_ results: [SubtreeValue], _ value: (SubtreeValue) -> Double?) -> SubtreeValue? {
            var best: SubtreeValue? = nil
            var bestValue = -Double.infinity
            for result in results {
                guard let v = value(result) else { continue }
                if best == nil || v > bestValue {
                    best = result
                    bestValue = v
                }
            }
            return best
        }

        // Returns (user's policy value, counterpart's own value, whether opt-mode was used).
        func visit(_ node: Node) -> (user: Double?, counterpart: Double?, usedOpt: Bool) {
            if node.isTerminal {
                let userValue = node.payoff.map { unit.scalar(of: $0) }
                var counterpartValue: Double? = nil
                if case .optimizesOwnPayoff(let component) = mode,
                    case .components(let dict)? = node.payoff {
                    counterpartValue = dict[component]
                }
                accumulator[node.id] = PolicyAnnotation(
                    value: userValue, optimalChildId: nil, usedCounterpartOptimization: false)
                return (userValue, counterpartValue, false)
            }

            var results: [SubtreeValue] = []
            for child in node.children ?? [] {
                let sub = visit(child)
                results.append(SubtreeValue(
                    child: child, user: sub.user, counterpart: sub.counterpart, usedOpt: sub.usedOpt))
            }

            var value: Double? = nil
            var optimalChildId: String? = nil
            var counterpartValue: Double? = nil
            var usedOpt = results.contains { $0.usedOpt }

            switch node.actor {
            case .user:
                // Max over valued children; ties break to the first (stable order).
                if let best = bestBy(results, { $0.user }) {
                    value = best.user
                    optimalChildId = best.child.id
                    counterpartValue = best.counterpart
                }
            case .counterpart:
                var optimized = false
                if case .optimizesOwnPayoff = mode {
                    if let best = bestBy(results, { $0.counterpart }) {
                        value = best.user
                        optimalChildId = best.child.id
                        counterpartValue = best.counterpart
                        usedOpt = true
                        optimized = true
                    }
                }
                if !optimized {
                    // .listedProbabilities mode, or fallback when no child has counterpart payoffs.
                    value = probabilityWeighted(results) { $0.user }
                    counterpartValue = probabilityWeighted(results) { $0.counterpart }
                }
            case .chance:
                value = probabilityWeighted(results) { $0.user }
                counterpartValue = probabilityWeighted(results) { $0.counterpart }
            }

            accumulator[node.id] = PolicyAnnotation(
                value: value, optimalChildId: optimalChildId, usedCounterpartOptimization: usedOpt)
            return (value, counterpartValue, usedOpt)
        }

        _ = visit(root)
        self.byId = accumulator
    }
}
