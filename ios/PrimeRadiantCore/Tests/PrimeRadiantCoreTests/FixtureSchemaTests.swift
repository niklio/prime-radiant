import Foundation
import Testing
@testable import PrimeRadiantCore

/// The Swift models are a hand-mirror of shared/schema/*.schema.json (handoff §7):
/// these tests assert the mirror stays faithful against the shared sample.
@Suite struct FixtureSchemaTests {
    typealias J = Fixtures.JobOffer

    @Test func sampleScenarioDecodes() throws {
        let scenario = try Fixtures.jobOffer
        #expect(scenario.title == "counter the offer?")
        #expect(scenario.payoffUnit.kind == .currency)
        #expect(scenario.status == .modeling)
        #expect(scenario.realizedPath.isEmpty)
        #expect(Tree.count(scenario.tree) == 13)
    }

    @Test func sampleTreeIsStructurallyValid() throws {
        let scenario = try Fixtures.jobOffer
        try Patching.validate(tree: scenario.tree)
        // Sibling groups already sum to ~1 in the shipped sample.
        Tree.forEach(scenario.tree) { node in
            guard let children = node.children, !children.isEmpty else { return }
            let sum = children.reduce(0) { $0 + $1.p }
            #expect(abs(sum - 1) < 1e-6, "children of \(node.label)")
        }
        // Every id is a well-formed ULID.
        for id in Tree.allIds(scenario.tree) {
            #expect(ULID.isValid(id), "bad ULID \(id)")
        }
    }

    @Test func scenarioRoundTripsThroughJSON() throws {
        let scenario = try Fixtures.jobOffer
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(Scenario.self, from: encoder.encode(scenario))
        #expect(round == scenario)
    }

    @Test func depthAndActorCoverage() throws {
        // The sample must stay a real exercise: ≥4 levels below the root and all three actors.
        let scenario = try Fixtures.jobOffer
        #expect(Tree.path(scenario.tree, to: J.pushWin)?.count == 5)
        var actors = Set<Actor>()
        Tree.forEach(scenario.tree) { actors.insert($0.actor) }
        #expect(actors == Set(Actor.allCases))
    }

    @Test func ulidGeneration() {
        var rng = Fixtures.SeededRNG(seed: 42)
        let id = ULID.generate(now: Date(timeIntervalSince1970: 1_750_000_000), using: &rng)
        #expect(id.count == 26)
        #expect(ULID.isValid(id))
        // Timestamp prefix is monotonic in time.
        var rng2 = Fixtures.SeededRNG(seed: 43)
        let later = ULID.generate(now: Date(timeIntervalSince1970: 1_750_000_001), using: &rng2)
        #expect(String(later.prefix(10)) > String(id.prefix(10)))
    }
}
