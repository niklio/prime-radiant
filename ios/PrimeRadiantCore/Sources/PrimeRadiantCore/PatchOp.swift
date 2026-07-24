import Foundation

/// A single tree-mutation operation emitted by the model (shared/schema/patch.schema.json).
/// Applied transactionally: any invalid op rolls back the whole patch.
public enum PatchOp: Equatable, Sendable {
    case replaceTree(tree: Node)
    case upsertNode(parentId: String, node: Node)
    case updateNode(id: String, fields: NodeFields)
    case removeNode(id: String)
    case markReached(id: String)
    case setUnit(payoffUnit: PayoffUnit)
    case retitleScenario(title: String)
}

/// Partial<Node> minus id/children — structural changes go through upsert/remove.
public struct NodeFields: Codable, Equatable, Sendable {
    public var label: String?
    public var sub: String?
    public var p: Double?
    public var actor: Actor?
    public var move: String?
    public var note: String?
    public var payoff: Payoff?
    public var confidence: Confidence?

    public init(
        label: String? = nil, sub: String? = nil, p: Double? = nil, actor: Actor? = nil,
        move: String? = nil, note: String? = nil, payoff: Payoff? = nil,
        confidence: Confidence? = nil
    ) {
        self.label = label
        self.sub = sub
        self.p = p
        self.actor = actor
        self.move = move
        self.note = note
        self.payoff = payoff
        self.confidence = confidence
    }

    public var isEmpty: Bool {
        label == nil && sub == nil && p == nil && actor == nil
            && move == nil && note == nil && payoff == nil && confidence == nil
    }
}

extension PatchOp: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, tree, parentId, node, id, fields, payoffUnit, title
    }

    private enum OpName: String, Codable {
        case replace_tree, upsert_node, update_node, remove_node,
            mark_reached, set_unit, retitle_scenario
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(OpName.self, forKey: .op) {
        case .replace_tree:
            self = .replaceTree(tree: try container.decode(Node.self, forKey: .tree))
        case .upsert_node:
            self = .upsertNode(
                parentId: try container.decode(String.self, forKey: .parentId),
                node: try container.decode(Node.self, forKey: .node))
        case .update_node:
            self = .updateNode(
                id: try container.decode(String.self, forKey: .id),
                fields: try container.decode(NodeFields.self, forKey: .fields))
        case .remove_node:
            self = .removeNode(id: try container.decode(String.self, forKey: .id))
        case .mark_reached:
            self = .markReached(id: try container.decode(String.self, forKey: .id))
        case .set_unit:
            self = .setUnit(payoffUnit: try container.decode(PayoffUnit.self, forKey: .payoffUnit))
        case .retitle_scenario:
            self = .retitleScenario(title: try container.decode(String.self, forKey: .title))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .replaceTree(let tree):
            try container.encode(OpName.replace_tree, forKey: .op)
            try container.encode(tree, forKey: .tree)
        case .upsertNode(let parentId, let node):
            try container.encode(OpName.upsert_node, forKey: .op)
            try container.encode(parentId, forKey: .parentId)
            try container.encode(node, forKey: .node)
        case .updateNode(let id, let fields):
            try container.encode(OpName.update_node, forKey: .op)
            try container.encode(id, forKey: .id)
            try container.encode(fields, forKey: .fields)
        case .removeNode(let id):
            try container.encode(OpName.remove_node, forKey: .op)
            try container.encode(id, forKey: .id)
        case .markReached(let id):
            try container.encode(OpName.mark_reached, forKey: .op)
            try container.encode(id, forKey: .id)
        case .setUnit(let payoffUnit):
            try container.encode(OpName.set_unit, forKey: .op)
            try container.encode(payoffUnit, forKey: .payoffUnit)
        case .retitleScenario(let title):
            try container.encode(OpName.retitle_scenario, forKey: .op)
            try container.encode(title, forKey: .title)
        }
    }
}

/// The structured output contract for every model turn: `{ say, patch? }`.
/// Free text never touches the tree.
public struct ModelTurn: Codable, Equatable, Sendable {
    public var say: String
    public var patch: [PatchOp]?

    public init(say: String, patch: [PatchOp]? = nil) {
        self.say = say
        self.patch = patch
    }
}
