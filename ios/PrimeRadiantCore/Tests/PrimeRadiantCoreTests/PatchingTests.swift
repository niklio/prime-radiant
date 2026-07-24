import Foundation
import Testing
@testable import PrimeRadiantCore

@Suite struct PatchingTests {
    typealias J = Fixtures.JobOffer
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func updateNodeEditsPayoffAndRecomputes() throws {
        let scenario = try Fixtures.jobOffer
        let patched = try Patching.apply(
            [.updateNode(id: J.rescind, fields: NodeFields(payoff: .scalar(-80)))],
            to: scenario, at: now)
        #expect(Tree.find(patched.tree, id: J.rescind)?.payoff == .scalar(-80))
        #expect(patched.updatedAt == now)
        // "Make losing the client −80 instead of −40" shifts EV: counter −8→−16 at .2 mass.
        let a = TreeAnalytics(tree: patched.tree, realizedPath: [], unit: patched.payoffUnit)
        #expect(abs(a[J.counter]!.ev! - (3.752 - 8)) < 1e-9)
    }

    @Test func upsertAddsAndReplaces() throws {
        let scenario = try Fixtures.jobOffer
        let newLeaf = Node(
            id: "01J0PRNEWBRANCH00000000000", label: "they delay", p: 0.1, actor: .counterpart,
            payoff: .scalar(-5), confidence: .assumed)
        let added = try Patching.apply([.upsertNode(parentId: J.counter, node: newLeaf)], to: scenario, at: now)
        #expect(Tree.find(added.tree, id: newLeaf.id) != nil)
        // Sibling probabilities renormalize: .35+.45+.2+.1 = 1.1 → scale by 1/1.1.
        #expect(abs(Tree.find(added.tree, id: J.counterAccept)!.p - 0.35 / 1.1) < 1e-9)

        var replacement = newLeaf
        replacement.payoff = .scalar(-2)
        let replaced = try Patching.apply(
            [.upsertNode(parentId: J.counter, node: replacement)], to: added, at: now)
        #expect(Tree.find(replaced.tree, id: newLeaf.id)?.payoff == .scalar(-2))
        // Replacement, not duplication.
        #expect(Tree.find(replaced.tree, id: J.counter)!.children!.count == 4)
    }

    @Test func upsertRejectsIdLivingElsewhere() throws {
        let scenario = try Fixtures.jobOffer
        let stolen = Node(id: J.accept, label: "imposter", p: 0.5, actor: .user)
        #expect(throws: Patching.PatchError.duplicateNodeId(J.accept)) {
            try Patching.apply([.upsertNode(parentId: J.counter, node: stolen)], to: scenario, at: now)
        }
    }

    @Test func removeNodeAndRootProtection() throws {
        let scenario = try Fixtures.jobOffer
        let removed = try Patching.apply([.removeNode(id: J.decline)], to: scenario, at: now)
        #expect(Tree.find(removed.tree, id: J.declineBetter) == nil)
        // Remaining siblings renormalize to sum 1.
        let children = Tree.find(removed.tree, id: J.root)!.children!
        #expect(abs(children.reduce(0) { $0 + $1.p } - 1) < 1e-9)
        #expect(throws: Patching.PatchError.cannotRemoveRoot) {
            try Patching.apply([.removeNode(id: J.root)], to: scenario, at: now)
        }
    }

    @Test func removingRealizedNodeTruncatesPath() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.meet)
        let patched = try Patching.apply([.removeNode(id: J.meet)], to: marked, at: now)
        #expect(patched.realizedPath == [J.root, J.counter])
    }

    @Test func markReachedOpMatchesGestureSemantics() throws {
        let scenario = try Fixtures.jobOffer
        let patched = try Patching.apply([.markReached(id: J.meet)], to: scenario, at: now)
        #expect(patched.realizedPath == [J.root, J.counter, J.meet])
        #expect(Tree.find(patched.tree, id: J.meet)?.reached == true)
    }

    @Test func replaceTreePreservesValidRealizedPrefix() throws {
        let marked = try Marking.mark(try Fixtures.jobOffer, id: J.counter)
        // New tree keeps root+counter but reshapes below.
        var newTree = marked.tree
        newTree = Tree.updating(newTree, id: J.counter) { $0.children = [
            Node(id: "01J0PRRESHAPED000000000000", label: "fresh", p: 1, actor: .user, payoff: .scalar(1))
        ] }!
        let patched = try Patching.apply([.replaceTree(tree: newTree)], to: marked, at: now)
        #expect(patched.realizedPath == [J.root, J.counter])

        // Replacing with an unrelated tree clears the path.
        let unrelated = Node(id: "01J0PRBRANDNEW000000000000", label: "new", p: 1, actor: .user)
        let cleared = try Patching.apply([.replaceTree(tree: unrelated)], to: marked, at: now)
        #expect(cleared.realizedPath.isEmpty)
    }

    @Test func setUnitAndRetitle() throws {
        let scenario = try Fixtures.jobOffer
        let unit = PayoffUnit(kind: .scale, label: "0–100")
        let patched = try Patching.apply(
            [.setUnit(payoffUnit: unit), .retitleScenario(title: "renamed")], to: scenario, at: now)
        #expect(patched.payoffUnit == unit)
        #expect(patched.title == "renamed")
    }

    @Test func invalidOpRollsBackWholePatch() throws {
        let scenario = try Fixtures.jobOffer
        // First op is valid, second is not: nothing may stick (transactional).
        let ops: [PatchOp] = [
            .updateNode(id: J.accept, fields: NodeFields(payoff: .scalar(99))),
            .removeNode(id: "01J0PRABSENT00000000000000"),
        ]
        #expect(throws: Patching.PatchError.nodeNotFound("01J0PRABSENT00000000000000")) {
            try Patching.apply(ops, to: scenario, at: now)
        }
        // Caller's copy is untouched by construction; verify the valid prefix alone applies.
        let partial = try Patching.apply([ops[0]], to: scenario, at: now)
        #expect(Tree.find(partial.tree, id: J.accept)?.payoff == .scalar(99))
        #expect(Tree.find(scenario.tree, id: J.accept)?.payoff == .scalar(0))
    }

    @Test func invalidProbabilityRejected() throws {
        let scenario = try Fixtures.jobOffer
        #expect(throws: Patching.PatchError.self) {
            try Patching.apply(
                [.updateNode(id: J.accept, fields: NodeFields(p: 1.5))], to: scenario, at: now)
        }
        #expect(throws: Patching.PatchError.self) {
            try Patching.apply(
                [.updateNode(id: J.accept, fields: NodeFields(p: -0.1))], to: scenario, at: now)
        }
    }

    @Test func emptyUpdateRejected() throws {
        let scenario = try Fixtures.jobOffer
        #expect(throws: Patching.PatchError.emptyUpdate(J.accept)) {
            try Patching.apply([.updateNode(id: J.accept, fields: NodeFields())], to: scenario, at: now)
        }
    }
}
