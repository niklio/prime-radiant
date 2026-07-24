import Foundation
import Testing
@testable import PrimeRadiantCore

@Suite struct ConditioningTests {
    typealias J = Fixtures.JobOffer

    @Test func markingRealizesWholePathAndFlagsNodes() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.meet)
        #expect(marked.realizedPath == [J.root, J.counter, J.meet])
        #expect(Tree.find(marked.tree, id: J.counter)?.reached == true)
        #expect(Tree.find(marked.tree, id: J.meet)?.reached == true)
        #expect(Tree.find(marked.tree, id: J.accept)?.reached != true)
        #expect(marked.status == .in_progress)
    }

    @Test func conditionedEvAtRootEqualsRawEvOfDeepestMark() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.meet)
        let a = TreeAnalytics(tree: marked.tree, realizedPath: marked.realizedPath, unit: marked.payoffUnit)
        // Path probability collapses to 1; below the mark, raw probabilities apply.
        #expect(abs(a[J.root]!.conditionedEv! - 10.56) < 1e-9)
        #expect(abs(a[J.meet]!.conditionedCumulativeProbability - 1) < 1e-9)
    }

    @Test func unrealizedSiblingsGhostAndDropFromLiveFigures() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.counter)
        let a = TreeAnalytics(tree: marked.tree, realizedPath: marked.realizedPath, unit: marked.payoffUnit)
        #expect(a[J.accept]!.isGhost)
        #expect(a[J.decline]!.isGhost)
        #expect(!a[J.counter]!.isGhost)
        #expect(a[J.accept]!.conditionedCumulativeProbability == 0)
        // Ghosts retain raw values for hindsight display.
        #expect(abs(a[J.decline]!.ev! - (-5)) < 1e-9)
        #expect(abs(a[J.decline]!.cumulativeProbability - 0.15) < 1e-9)
        // Live root distribution excludes ghost mass.
        #expect(a[J.root]!.conditionedDistribution.allSatisfy { $0.mass > 0 })
        #expect(abs(a[J.root]!.conditionedEv! - 3.752) < 1e-9)
    }

    @Test func conditioningNeverChangesTerminalPayoffs() throws {
        let scenario = try Fixtures.jobOffer
        let raw = TreeAnalytics(tree: scenario.tree, realizedPath: [], unit: scenario.payoffUnit)
        let marked = try Marking.mark(scenario, id: J.push)
        let conditioned = TreeAnalytics(tree: marked.tree, realizedPath: marked.realizedPath, unit: marked.payoffUnit)
        let rawPayoffs = Set(raw[J.root]!.distribution.map(\.payoff))
        let conditionedPayoffs = Set(conditioned[J.root]!.conditionedDistribution.map(\.payoff))
        #expect(conditionedPayoffs.isSubset(of: rawPayoffs))
    }

    @Test func unmarkDrainsBackToParent() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.meet)
        let unmarked = try Marking.unmark(marked, id: J.meet)
        #expect(unmarked.realizedPath == [J.root, J.counter])
        #expect(Tree.find(unmarked.tree, id: J.meet)?.reached != true)
        #expect(Tree.find(unmarked.tree, id: J.counter)?.reached == true)
    }

    @Test func unmarkMidPathDropsDescendants() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.take)
        let unmarked = try Marking.unmark(marked, id: J.counter)
        // Path shrinks to the root alone → no meaningful mark remains.
        #expect(unmarked.realizedPath.isEmpty)
        #expect(Tree.find(unmarked.tree, id: J.take)?.reached != true)
    }

    @Test func unmarkOffPathIsNoOp() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.counter)
        let same = try Marking.unmark(marked, id: J.decline)
        #expect(same.realizedPath == marked.realizedPath)
    }

    @Test func resolveMarksTerminalAndRecordsActual() throws {
        let resolved = try Marking.resolve(try Fixtures.jobOffer, terminalId: J.take, actualPayoff: 8)
        #expect(resolved.status == .resolved)
        #expect(resolved.resolvedPayoff == 8)
        #expect(resolved.realizedPath == [J.root, J.counter, J.meet, J.take])
    }

    @Test func resolveRejectsNonTerminal() throws {
        #expect(throws: Marking.MarkError.self) {
            try Marking.resolve(try Fixtures.jobOffer, terminalId: J.counter, actualPayoff: nil)
        }
    }

    @Test func reconcileKeepsLongestValidPrefix() throws {
        let scenario = try Fixtures.jobOffer
        let stale = [J.root, J.counter, "01J0PRG0NE0000000000000000", J.take]
        #expect(Marking.reconciled(path: stale, tree: scenario.tree) == [J.root, J.counter])
        #expect(Marking.reconciled(path: ["01J0PRG0NE0000000000000000"], tree: scenario.tree).isEmpty)
        #expect(Marking.reconciled(path: [J.root], tree: scenario.tree).isEmpty)
    }
}
