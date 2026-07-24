import Foundation

/// Transactional patch application (handoff §5.1). All ops in a patch apply or none do:
/// the caller's scenario is untouched unless every op validates. After a successful
/// patch, sibling probabilities are renormalized and the realized path is reconciled.
public enum Patching {

    public enum PatchError: Error, Equatable {
        case parentNotFound(String)
        case nodeNotFound(String)
        case duplicateNodeId(String)
        case cannotRemoveRoot
        case cannotUpdateRootProbability
        case emptyUpdate(String)
        case invalidProbability(id: String, p: Double)
        case invalidTree(String)
    }

    public static func apply(_ ops: [PatchOp], to scenario: Scenario, at date: Date) throws -> Scenario {
        var copy = scenario
        for op in ops {
            copy = try applyOne(op, to: copy)
        }
        copy.tree = Tree.renormalized(copy.tree)
        copy.realizedPath = Marking.reconciled(path: copy.realizedPath, tree: copy.tree)
        copy.tree = Marking.applyingReachedFlags(copy.tree, realized: Set(copy.realizedPath))
        copy.updatedAt = date
        return copy
    }

    private static func applyOne(_ op: PatchOp, to scenario: Scenario) throws -> Scenario {
        var copy = scenario
        switch op {
        case .replaceTree(let tree):
            try validate(tree: tree)
            copy.tree = tree

        case .upsertNode(let parentId, let node):
            try validate(tree: node)
            guard Tree.contains(copy.tree, id: parentId) else {
                throw PatchError.parentNotFound(parentId)
            }
            // Upsert: replace in place if the id already lives under this parent;
            // otherwise append. An id existing elsewhere in the tree is a conflict.
            let existingPath = Tree.path(copy.tree, to: node.id)
            if let existingPath, existingPath.dropLast().last != parentId {
                throw PatchError.duplicateNodeId(node.id)
            }
            if node.id == copy.tree.id { throw PatchError.duplicateNodeId(node.id) }
            let updated = Tree.updating(copy.tree, id: parentId) { parent in
                var children = parent.children ?? []
                if let index = children.firstIndex(where: { $0.id == node.id }) {
                    children[index] = node
                } else {
                    children.append(node)
                }
                parent.children = children
            }
            guard let updated else { throw PatchError.parentNotFound(parentId) }
            try validate(tree: updated)
            copy.tree = updated

        case .updateNode(let id, let fields):
            guard !fields.isEmpty else { throw PatchError.emptyUpdate(id) }
            if let p = fields.p {
                guard p >= 0, p <= 1, p.isFinite else {
                    throw PatchError.invalidProbability(id: id, p: p)
                }
                if id == copy.tree.id { throw PatchError.cannotUpdateRootProbability }
            }
            let updated = Tree.updating(copy.tree, id: id) { node in
                if let label = fields.label { node.label = label }
                if let sub = fields.sub { node.sub = sub }
                if let p = fields.p { node.p = p }
                if let actor = fields.actor { node.actor = actor }
                if let move = fields.move { node.move = move }
                if let note = fields.note { node.note = note }
                if let payoff = fields.payoff { node.payoff = payoff }
                if let confidence = fields.confidence { node.confidence = confidence }
            }
            guard let updated else { throw PatchError.nodeNotFound(id) }
            copy.tree = updated

        case .removeNode(let id):
            guard id != copy.tree.id else { throw PatchError.cannotRemoveRoot }
            guard let updated = Tree.removing(copy.tree, id: id) else {
                throw PatchError.nodeNotFound(id)
            }
            copy.tree = updated

        case .markReached(let id):
            copy = try Marking.mark(copy, id: id)

        case .setUnit(let payoffUnit):
            copy.payoffUnit = payoffUnit

        case .retitleScenario(let title):
            copy.title = title
        }
        return copy
    }

    /// Structural validation of a (sub)tree: unique ids, finite probabilities in [0,1].
    static func validate(tree: Node) throws {
        var seen = Set<String>()
        var duplicate: String? = nil
        var badProbability: (String, Double)? = nil
        Tree.forEach(tree) { node in
            if !seen.insert(node.id).inserted, duplicate == nil { duplicate = node.id }
            if !(node.p >= 0 && node.p <= 1 && node.p.isFinite), badProbability == nil {
                badProbability = (node.id, node.p)
            }
        }
        if let duplicate { throw PatchError.duplicateNodeId(duplicate) }
        if let badProbability {
            throw PatchError.invalidProbability(id: badProbability.0, p: badProbability.1)
        }
    }
}
