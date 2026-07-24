import Foundation
import Testing
@testable import PrimeRadiantCore

@Suite struct PolicyTests {
    typealias J = Fixtures.JobOffer

    // Backward-induction oracle for the sample (listed-p mode):
    //   meet (user):    max(take 10, push 12.8)            = 12.8 via push
    //   counter (cpart, listed p): .35×20+.45×12.8+.2×(−40) = 4.76
    //   root (user):    max(accept 0, counter 4.76, decline −5) = 4.76 via counter
    @Test func backwardInductionListedProbabilities() throws {
        let scenario = try Fixtures.jobOffer
        let policy = PolicyAnalysis(tree: scenario.tree, unit: scenario.payoffUnit)
        #expect(policy[J.meet]!.optimalChildId == J.push)
        #expect(abs(policy[J.meet]!.value! - 12.8) < 1e-9)
        #expect(abs(policy[J.counter]!.value! - 4.76) < 1e-9)
        #expect(policy[J.counter]!.optimalChildId == nil)  // listed-p: no deterministic pick
        #expect(policy[J.root]!.optimalChildId == J.counter)
        #expect(abs(policy[J.root]!.value! - 4.76) < 1e-9)
        #expect(!policy[J.root]!.usedCounterpartOptimization)
    }

    @Test func chanceNodesAlwaysWeightByListedP() throws {
        let scenario = try Fixtures.jobOffer
        let policy = PolicyAnalysis(tree: scenario.tree, unit: scenario.payoffUnit)
        #expect(abs(policy[J.push]!.value! - 12.8) < 1e-9)
        #expect(policy[J.push]!.optimalChildId == nil)
        #expect(abs(policy[J.decline]!.value! - (-5)) < 1e-9)
    }

    /// A tree where the two counterpart modes disagree:
    /// negotiate (counterpart): accept {us 10, them 5} p .7 · reject {us −5, them 8} p .3
    /// walk: terminal, us 0.
    /// Listed p: negotiate = .7×10+.3×(−5) = 5.5 → root picks negotiate.
    /// Optimizing counterpart: picks reject (them 8) → negotiate = −5 → root picks walk.
    func modesTree() -> (Scenario, root: String, negotiate: String, walk: String, accept: String, reject: String) {
        let root = "00000000000000000000000000"
        let negotiate = "00000000000000000000000001"
        let walk = "00000000000000000000000002"
        let accept = "00000000000000000000000003"
        let reject = "00000000000000000000000004"
        let tree = Node(
            id: root, label: "root", p: 1, actor: .user,
            children: [
                Node(
                    id: negotiate, label: "negotiate", p: 0.8, actor: .counterpart,
                    children: [
                        Node(id: accept, label: "they accept", p: 0.7, actor: .counterpart,
                             payoff: .components(["us": 10, "them": 5])),
                        Node(id: reject, label: "they reject", p: 0.3, actor: .counterpart,
                             payoff: .components(["us": -5, "them": 8])),
                    ]),
                Node(id: walk, label: "walk", p: 0.2, actor: .user, payoff: .components(["us": 0])),
            ])
        let unit = PayoffUnit(
            kind: .utils, label: "us-weighted",
            components: [.init(name: "us", weight: 1), .init(name: "them", weight: 0)])
        return (Fixtures.scenario(tree: tree, unit: unit), root, negotiate, walk, accept, reject)
    }

    @Test func counterpartModesDisagreeAsDesigned() {
        let (scenario, root, negotiate, walk, _, reject) = modesTree()

        let listed = PolicyAnalysis(tree: scenario.tree, unit: scenario.payoffUnit, mode: .listedProbabilities)
        #expect(abs(listed[negotiate]!.value! - 5.5) < 1e-9)
        #expect(listed[root]!.optimalChildId == negotiate)
        #expect(!listed[root]!.usedCounterpartOptimization)

        let optimizing = PolicyAnalysis(
            tree: scenario.tree, unit: scenario.payoffUnit, mode: .optimizesOwnPayoff(component: "them"))
        #expect(optimizing[negotiate]!.value! == -5)
        #expect(optimizing[negotiate]!.optimalChildId == reject)
        #expect(optimizing[negotiate]!.usedCounterpartOptimization)
        #expect(optimizing[root]!.optimalChildId == walk)
        #expect(optimizing[root]!.value! == 0)
    }

    @Test func optimizingModeFallsBackWhereComponentAbsent() throws {
        // The job-offer sample has scalar payoffs only → no "them" component anywhere:
        // optimizing mode must reduce to listed-p everywhere.
        let scenario = try Fixtures.jobOffer
        let listed = PolicyAnalysis(tree: scenario.tree, unit: scenario.payoffUnit)
        let optimizing = PolicyAnalysis(
            tree: scenario.tree, unit: scenario.payoffUnit, mode: .optimizesOwnPayoff(component: "them"))
        #expect(abs(optimizing[J.root]!.value! - listed[J.root]!.value!) < 1e-9)
        #expect(!optimizing[J.root]!.usedCounterpartOptimization)
    }

    @Test func userNodeSkipsValuelessChildren() {
        // A user node with one valued child and one payoff-less child picks the valued one.
        let tree = Node(
            id: "00000000000000000000000000", label: "root", p: 1, actor: .user,
            children: [
                Node(id: "00000000000000000000000001", label: "unknown", p: 0.5, actor: .user),
                Node(id: "00000000000000000000000002", label: "known", p: 0.5, actor: .user, payoff: .scalar(-3)),
            ])
        let policy = PolicyAnalysis(tree: tree, unit: PayoffUnit(kind: .utils, label: "u"))
        #expect(policy["00000000000000000000000000"]!.optimalChildId == "00000000000000000000000002")
        #expect(policy["00000000000000000000000000"]!.value == -3)
    }
}
