import Foundation

// Canonical data model, mirroring shared/schema/*.schema.json.
// Schema-validation tests assert the mirror stays faithful (handoff §7).

public enum Actor: String, Codable, Sendable, CaseIterable {
    case user, counterpart, chance
}

public enum Confidence: String, Codable, Sendable, CaseIterable {
    case estimated, user_set, assumed
}

/// A terminal payoff: a scalar in the scenario unit, or named components
/// whose weighted scalar is derived client-side (never model-supplied).
public enum Payoff: Equatable, Sendable {
    case scalar(Double)
    case components([String: Double])
}

extension Payoff: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .scalar(value)
        } else {
            let dict = try container.decode([String: Double].self)
            guard !dict.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "component payoff must be non-empty")
            }
            self = .components(dict)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .scalar(let value): try container.encode(value)
        case .components(let dict): try container.encode(dict)
        }
    }
}

public struct PayoffUnit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case currency, utils, scale }
    public struct Component: Codable, Equatable, Sendable {
        public var name: String
        public var weight: Double
        public init(name: String, weight: Double) {
            self.name = name
            self.weight = weight
        }
    }

    public var kind: Kind
    public var label: String
    public var components: [Component]?

    public init(kind: Kind, label: String, components: [Component]? = nil) {
        self.kind = kind
        self.label = label
        self.components = components
    }

    /// Collapse a payoff to the scenario's weighted scalar.
    /// Components without a declared weight contribute with weight 1.
    public func scalar(of payoff: Payoff) -> Double {
        switch payoff {
        case .scalar(let value):
            return value
        case .components(let dict):
            let weights = Dictionary(uniqueKeysWithValues: (components ?? []).map { ($0.name, $0.weight) })
            return dict.reduce(0) { $0 + $1.value * (weights[$1.key] ?? 1.0) }
        }
    }
}

public struct Node: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var sub: String?
    /// Conditional probability among siblings (siblings sum ~1; the app renormalizes).
    public var p: Double
    public var actor: Actor
    public var move: String?
    public var note: String?
    public var payoff: Payoff?
    public var confidence: Confidence?
    public var reached: Bool?
    public var children: [Node]?

    public init(
        id: String, label: String, sub: String? = nil, p: Double, actor: Actor,
        move: String? = nil, note: String? = nil, payoff: Payoff? = nil,
        confidence: Confidence? = nil, reached: Bool? = nil, children: [Node]? = nil
    ) {
        self.id = id
        self.label = label
        self.sub = sub
        self.p = p
        self.actor = actor
        self.move = move
        self.note = note
        self.payoff = payoff
        self.confidence = confidence
        self.reached = reached
        self.children = children
    }

    public var isTerminal: Bool { children?.isEmpty ?? true }
}

public enum ScenarioStatus: String, Codable, Sendable {
    case modeling, in_progress, resolved
}

public struct Message: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var content: String
    public var timestamp: Date
    public var patchApplied: String?

    public init(role: Role, content: String, timestamp: Date, patchApplied: String? = nil) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.patchApplied = patchApplied
    }
}

public struct Scenario: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var payoffUnit: PayoffUnit
    public var status: ScenarioStatus
    public var tree: Node
    /// Ordered node ids, root-first; empty until the first mark.
    public var realizedPath: [String]
    public var resolvedPayoff: Double?
    public var transcript: [Message]
    public var cameraState: [String: Double]?

    public init(
        id: String, title: String, createdAt: Date, updatedAt: Date,
        payoffUnit: PayoffUnit, status: ScenarioStatus, tree: Node,
        realizedPath: [String] = [], resolvedPayoff: Double? = nil,
        transcript: [Message] = [], cameraState: [String: Double]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payoffUnit = payoffUnit
        self.status = status
        self.tree = tree
        self.realizedPath = realizedPath
        self.resolvedPayoff = resolvedPayoff
        self.transcript = transcript
        self.cameraState = cameraState
    }
}
