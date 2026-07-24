import Foundation

/// Branch tracking: marking reality (handoff §2.3). Marking a node realizes the whole
/// path root→node; unmarking a node drops it and everything below it from the path.
/// `reached` flags on nodes and `realizedPath` on the scenario are kept consistent.
public enum Marking {

    public enum MarkError: Error, Equatable {
        case nodeNotFound(String)
    }

    /// Mark `id` as reached. Idempotent.
    public static func mark(_ scenario: Scenario, id: String) throws -> Scenario {
        guard let path = Tree.path(scenario.tree, to: id) else {
            throw MarkError.nodeNotFound(id)
        }
        var copy = scenario
        copy.realizedPath = path
        copy.tree = applyingReachedFlags(copy.tree, realized: Set(path))
        if copy.status == .modeling { copy.status = .in_progress }
        return copy
    }

    /// Unmark `id`: the realized path shrinks to `id`'s ancestors.
    /// Unmarking a node that isn't on the realized path is a no-op.
    public static func unmark(_ scenario: Scenario, id: String) throws -> Scenario {
        guard Tree.contains(scenario.tree, id: id) else {
            throw MarkError.nodeNotFound(id)
        }
        guard let index = scenario.realizedPath.firstIndex(of: id) else { return scenario }
        var copy = scenario
        copy.realizedPath = Array(copy.realizedPath.prefix(upTo: index))
        // A bare root entry is not a meaningful mark.
        if copy.realizedPath.count <= 1 { copy.realizedPath = [] }
        copy.tree = applyingReachedFlags(copy.tree, realized: Set(copy.realizedPath))
        return copy
    }

    /// Resolve flow (terminal node held): mark it and record the actual payoff if given.
    public static func resolve(_ scenario: Scenario, terminalId: String, actualPayoff: Double?) throws -> Scenario {
        guard let node = Tree.find(scenario.tree, id: terminalId), node.isTerminal else {
            throw MarkError.nodeNotFound(terminalId)
        }
        var copy = try mark(scenario, id: terminalId)
        copy.status = .resolved
        copy.resolvedPayoff = actualPayoff
        return copy
    }

    /// Reconcile a stored realizedPath against a (possibly restructured) tree:
    /// keep the longest prefix that is still a valid root-descending chain.
    public static func reconciled(path: [String], tree: Node) -> [String] {
        guard path.first == tree.id else { return [] }
        var valid: [String] = [tree.id]
        var node = tree
        for id in path.dropFirst() {
            guard let child = node.children?.first(where: { $0.id == id }) else { break }
            valid.append(id)
            node = child
        }
        return valid.count <= 1 ? [] : valid
    }

    static func applyingReachedFlags(_ root: Node, realized: Set<String>) -> Node {
        var copy = root
        copy.reached = realized.contains(copy.id) ? true : nil
        copy.children = copy.children?.map { applyingReachedFlags($0, realized: realized) }
        return copy
    }
}
