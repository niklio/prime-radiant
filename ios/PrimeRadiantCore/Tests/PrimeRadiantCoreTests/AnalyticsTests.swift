import Foundation
import Testing
@testable import PrimeRadiantCore

// Hand-computed oracle for the job-offer sample (renormalized probabilities):
//   push  EV = .4×17 + .6×10                     = 12.8
//   meet  EV = .8×10 + .2×12.8                   = 10.56
//   counter EV = .35×20 + .45×10.56 + .2×(−40)   = 3.752
//   decline EV = .5×15 + .5×(−25)                = −5
//   root  EV = .2×0 + .65×3.752 + .15×(−5)       = 1.6888
@Suite struct AnalyticsTests {
    typealias J = Fixtures.JobOffer

    func analytics(_ scenario: Scenario) -> TreeAnalytics {
        TreeAnalytics(tree: scenario.tree, realizedPath: scenario.realizedPath, unit: scenario.payoffUnit)
    }

    @Test func evMatchesHandComputedOracle() throws {
        let a = analytics(try Fixtures.jobOffer)
        #expect(abs(a[J.push]!.ev! - 12.8) < 1e-9)
        #expect(abs(a[J.meet]!.ev! - 10.56) < 1e-9)
        #expect(abs(a[J.counter]!.ev! - 3.752) < 1e-9)
        #expect(abs(a[J.decline]!.ev! - (-5)) < 1e-9)
        #expect(abs(a[J.root]!.ev! - 1.6888) < 1e-9)
    }

    @Test func terminalEvIsItsPayoff() throws {
        let a = analytics(try Fixtures.jobOffer)
        #expect(a[J.rescind]!.ev == -40)
        #expect(a[J.accept]!.ev == 0)
    }

    @Test func cumulativeProbabilities() throws {
        let a = analytics(try Fixtures.jobOffer)
        #expect(abs(a[J.root]!.cumulativeProbability - 1) < 1e-9)
        #expect(abs(a[J.meet]!.cumulativeProbability - 0.65 * 0.45) < 1e-9)
        #expect(abs(a[J.pushWin]!.cumulativeProbability - 0.65 * 0.45 * 0.2 * 0.4) < 1e-9)
    }

    @Test func rootDistributionIsExactAndMergedByPayoff() throws {
        let a = analytics(try Fixtures.jobOffer)
        let dist = a[J.root]!.distribution
        // Payoffs 10 (take) and 10 (push-hold) merge: 7 distinct payoffs from 8 terminals.
        #expect(dist.count == 7)
        #expect(abs(dist.reduce(0) { $0 + $1.mass } - 1) < 1e-9)
        let ten = dist.first { $0.payoff == 10 }!
        #expect(abs(ten.mass - (0.65 * 0.45 * 0.8 + 0.65 * 0.45 * 0.2 * 0.6)) < 1e-9)
        // Sorted ascending by payoff.
        #expect(dist.map(\.payoff) == dist.map(\.payoff).sorted())
    }

    @Test func binningCapsAtSixAndClassesOutcomes() throws {
        let a = analytics(try Fixtures.jobOffer)
        let bins = TreeAnalytics.binned(a[J.root]!.distribution, maxBins: 6)
        #expect(bins.count <= 6)
        #expect(abs(bins.reduce(0) { $0 + $1.mass } - 1) < 1e-9)
        // Range −40…20, width 10: nonempty bins are [−40,−30), [−30,−20), [0,10), [10,20].
        #expect(bins.count == 4)
        #expect(bins[0].outcomeClass == .adverse)
        #expect(bins.last!.outcomeClass == .favorable)
        #expect(abs(bins.last!.mass - 0.595) < 1e-9)
    }

    @Test func fewDistinctPayoffsGetOneBinEach() {
        let points = [
            DistributionPoint(payoff: -5, mass: 0.5),
            DistributionPoint(payoff: 5, mass: 0.5),
        ]
        let bins = TreeAnalytics.binned(points, maxBins: 6)
        #expect(bins.count == 2)
        #expect(bins[0].outcomeClass == .adverse)
        #expect(bins[1].outcomeClass == .favorable)
    }

    @Test func bestWorstTerminalBounds() throws {
        let a = analytics(try Fixtures.jobOffer)
        #expect(a[J.root]!.bestTerminal == 20)
        #expect(a[J.root]!.worstTerminal == -40)
        #expect(a[J.meet]!.bestTerminal == 17)
        #expect(a[J.meet]!.worstTerminal == 10)
    }

    @Test func payoffCoverageFullOnSample() throws {
        let a = analytics(try Fixtures.jobOffer)
        #expect(abs(a[J.root]!.payoffCoverage - 1) < 1e-9)
    }

    @Test func missingTerminalPayoffLowersCoverageNotEv() {
        // Two branches, one payoff-less: EV is over the covered mass only.
        let tree = Node(
            id: "00000000000000000000000000", label: "root", p: 1, actor: .chance,
            children: [
                Node(id: "00000000000000000000000001", label: "a", p: 0.5, actor: .chance, payoff: .scalar(10)),
                Node(id: "00000000000000000000000002", label: "b", p: 0.5, actor: .chance),
            ])
        let a = TreeAnalytics(tree: tree, realizedPath: [], unit: PayoffUnit(kind: .utils, label: "u"))
        let root = a["00000000000000000000000000"]!
        #expect(abs(root.payoffCoverage - 0.5) < 1e-9)
        #expect(root.ev == 10)  // conditional on payoff-known mass
    }

    @Test func noPayoffsMeansNilEv() {
        let tree = Node(
            id: "00000000000000000000000000", label: "root", p: 1, actor: .user,
            children: [Node(id: "00000000000000000000000001", label: "a", p: 1, actor: .user)])
        let a = TreeAnalytics(tree: tree, realizedPath: [], unit: PayoffUnit(kind: .utils, label: "u"))
        #expect(a["00000000000000000000000000"]!.ev == nil)
        #expect(a["00000000000000000000000000"]!.distribution.isEmpty)
    }

    @Test func componentPayoffsUseWeightedScalar() {
        let unit = PayoffUnit(
            kind: .utils, label: "blend",
            components: [.init(name: "money", weight: 1), .init(name: "time", weight: 2)])
        let payoff = Payoff.components(["money": 10, "time": -3, "undeclared": 5])
        // 10×1 + (−3)×2 + 5×1 (undeclared components default to weight 1)
        #expect(unit.scalar(of: payoff) == 9)
    }
}
