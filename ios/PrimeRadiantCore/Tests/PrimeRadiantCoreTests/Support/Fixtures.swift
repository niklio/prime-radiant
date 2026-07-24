import Foundation
@testable import PrimeRadiantCore

enum Fixtures {
    /// Repo root, derived from this file's location (…/ios/PrimeRadiantCore/Tests/PrimeRadiantCoreTests/Support/Fixtures.swift).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Fixtures.swift → Support
            .deletingLastPathComponent()  // PrimeRadiantCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PrimeRadiantCore
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // repo root
    }

    static func loadScenario(named name: String) throws -> Scenario {
        let url = repoRoot.appendingPathComponent("shared/samples/\(name).json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Scenario.self, from: data)
    }

    static var jobOffer: Scenario {
        get throws { try loadScenario(named: "job-offer") }
    }

    // Ids in the job-offer sample.
    enum JobOffer {
        static let root = "01J0PRSAMPR00T000000000001"
        static let accept = "01J0PRSAMPACCEPT0000000002"
        static let counter = "01J0PRSAMPC0NTR00000000003"
        static let counterAccept = "01J0PRSAMPCACCEPT000000004"
        static let meet = "01J0PRSAMPCMEET00000000005"
        static let take = "01J0PRSAMPCMTAKE0000000006"
        static let push = "01J0PRSAMPCMPSH00000000007"
        static let pushWin = "01J0PRSAMPCMPWN00000000008"
        static let pushHold = "01J0PRSAMPCMPHD00000000009"
        static let rescind = "01J0PRSAMPCRSCND000000000A"
        static let decline = "01J0PRSAMPDECN00000000000B"
        static let declineBetter = "01J0PRSAMPDBETTER00000000C"
        static let declineWorse = "01J0PRSAMPDW0RSE000000000D"
    }

    /// Deterministic RNG for property tests (SplitMix64).
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Random tree for property tests: bounded depth/branching, random probabilities
    /// (deliberately unnormalized), payoffs on most terminals (some missing).
    static func randomTree(rng: inout SeededRNG, depth: Int = 0, maxDepth: Int = 4, counter: inout Int) -> Node {
        counter += 1
        let id = String(format: "%026d", counter)
        let actor = Actor.allCases[Int(rng.next() % 3)]
        let p = Double(rng.next() % 1000) / 500.0  // 0..2, unnormalized on purpose
        let childCount = depth >= maxDepth ? 0 : Int(rng.next() % 4)
        if childCount == 0 {
            let hasPayoff = rng.next() % 10 != 0  // ~90% of terminals carry payoffs
            let payoff = Double(Int64(bitPattern: rng.next() % 201) - 100)
            return Node(
                id: id, label: "n\(counter)", p: p, actor: actor,
                payoff: hasPayoff ? .scalar(payoff) : nil)
        }
        var children: [Node] = []
        for _ in 0..<childCount {
            children.append(randomTree(rng: &rng, depth: depth + 1, maxDepth: maxDepth, counter: &counter))
        }
        return Node(id: id, label: "n\(counter)", p: p, actor: actor, children: children)
    }

    static func scenario(tree: Node, realizedPath: [String] = [], unit: PayoffUnit? = nil) -> Scenario {
        Scenario(
            id: "01J0PRTEST0000000000000000",
            title: "test",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            payoffUnit: unit ?? PayoffUnit(kind: .currency, label: "USD"),
            status: .modeling,
            tree: tree,
            realizedPath: realizedPath)
    }
}
