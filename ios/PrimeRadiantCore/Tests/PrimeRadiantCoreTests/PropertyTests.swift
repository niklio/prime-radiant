import Foundation
import Testing
@testable import PrimeRadiantCore

/// Property tests (handoff §8): probabilities renormalize to 1; conditioning never
/// changes terminal payoffs; EV of a marked path's node equals conditional EV.
@Suite struct PropertyTests {

    let unit = PayoffUnit(kind: .utils, label: "u")

    func randomCase(seed: UInt64) -> (Node, [String]) {
        var rng = Fixtures.SeededRNG(seed: seed)
        var counter = 0
        var tree = Fixtures.randomTree(rng: &rng, counter: &counter)
        // Ensure the root has children often enough to be interesting.
        if tree.isTerminal {
            tree = Node(
                id: "R0000000000000000000000000", label: "root", p: 1, actor: .user,
                children: [tree, Fixtures.randomTree(rng: &rng, counter: &counter)])
        }
        return (tree, Tree.allIds(tree))
    }

    @Test(arguments: Array<UInt64>(1...50))
    func siblingProbabilitiesRenormalizeToOne(seed: UInt64) {
        let (tree, _) = randomCase(seed: seed)
        let normalized = Tree.renormalized(tree)
        #expect(normalized.p == 1)
        Tree.forEach(normalized) { node in
            guard let children = node.children, !children.isEmpty else { return }
            let sum = children.reduce(0) { $0 + $1.p }
            #expect(abs(sum - 1) < 1e-9, "children of \(node.id) sum to \(sum) (seed \(seed))")
        }
    }

    @Test(arguments: Array<UInt64>(1...50))
    func conditioningNeverChangesTerminalPayoffs(seed: UInt64) throws {
        let (tree, ids) = randomCase(seed: seed)
        var rng = Fixtures.SeededRNG(seed: seed &+ 999)
        let target = ids[Int(rng.next() % UInt64(ids.count))]
        let scenario = Fixtures.scenario(tree: tree, unit: unit)
        let marked = try Marking.mark(scenario, id: target)

        let raw = TreeAnalytics(tree: tree, realizedPath: [], unit: unit)
        let conditioned = TreeAnalytics(tree: marked.tree, realizedPath: marked.realizedPath, unit: unit)
        for id in ids {
            let rawPayoffs = Set(raw[id]!.distribution.map(\.payoff))
            let conditionedPayoffs = Set(conditioned[id]!.conditionedDistribution.map(\.payoff))
            #expect(conditionedPayoffs.isSubset(of: rawPayoffs), "node \(id) (seed \(seed))")
        }
    }

    @Test(arguments: Array<UInt64>(1...50))
    func conditionedRootEvEqualsRawEvOfDeepestMark(seed: UInt64) throws {
        let (tree, ids) = randomCase(seed: seed)
        var rng = Fixtures.SeededRNG(seed: seed &+ 31337)
        let target = ids[Int(rng.next() % UInt64(ids.count))]
        let scenario = Fixtures.scenario(tree: tree, unit: unit)
        let marked = try Marking.mark(scenario, id: target)
        let analytics = TreeAnalytics(tree: marked.tree, realizedPath: marked.realizedPath, unit: unit)

        let conditionedRoot = analytics[marked.tree.id]!.conditionedEv
        let rawAtMark = analytics[target]!.ev
        switch (conditionedRoot, rawAtMark) {
        case (nil, nil):
            break
        case (let a?, let b?):
            #expect(abs(a - b) < 1e-9, "seed \(seed), mark \(target)")
        default:
            Issue.record("EV nil-ness diverged (seed \(seed), mark \(target))")
        }
    }

    @Test(arguments: Array<UInt64>(1...30))
    func distributionMassEqualsPayoffCoverage(seed: UInt64) {
        // Total distribution mass at the root equals the payoff-carrying probability mass.
        let (tree, _) = randomCase(seed: seed)
        let analytics = TreeAnalytics(tree: tree, realizedPath: [], unit: unit)
        let root = analytics[tree.id]!
        let mass = root.distribution.reduce(0) { $0 + $1.mass }
        #expect(abs(mass - root.payoffCoverage) < 1e-9)
        #expect(root.payoffCoverage >= 0 && root.payoffCoverage <= 1 + 1e-9)
    }

    @Test(arguments: Array<UInt64>(1...30))
    func markThenUnmarkIsIdentityOnPathAndFlags(seed: UInt64) throws {
        let (tree, ids) = randomCase(seed: seed)
        var rng = Fixtures.SeededRNG(seed: seed &+ 7)
        let target = ids[Int(rng.next() % UInt64(ids.count))]
        let scenario = Fixtures.scenario(tree: tree, unit: unit)
        let marked = try Marking.mark(scenario, id: target)
        var unmarked = marked
        // Unmark from the deepest node back to the root.
        for id in marked.realizedPath.reversed() {
            unmarked = try Marking.unmark(unmarked, id: id)
        }
        #expect(unmarked.realizedPath.isEmpty)
        Tree.forEach(unmarked.tree) { #expect($0.reached != true) }
    }
}
