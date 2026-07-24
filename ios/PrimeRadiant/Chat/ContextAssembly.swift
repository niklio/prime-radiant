import Foundation
import PrimeRadiantCore

/// Context assembly for a model turn (handoff §5.3): rolling transcript digest +
/// the full tree JSON (the tree is the model's memory). If the serialized tree
/// exceeds budget, subtrees below depth 4 collapse to `{id,label,p,ev}` stubs,
/// keeping the subtree containing the current focus expanded.
///
/// Pure functions — unit-tested without any networking.
enum ContextAssembly {

    struct ContextItem: Equatable, Sendable {
        enum Role: String, Sendable { case system, user, assistant }
        var role: Role
        var text: String
    }

    /// Depth below which non-focus subtrees collapse under budget pressure.
    static let collapseDepth = 4

    // MARK: Transcript

    /// Rolling summary: recent turns travel verbatim, older turns compact into a
    /// deterministic digest line each (client-side; no model tokens spent on
    /// summarization).
    static func transcriptItems(_ transcript: [Message], keepLast: Int = 12) -> [ContextItem] {
        var items: [ContextItem] = []
        let older = transcript.dropLast(keepLast)
        if !older.isEmpty {
            let digest = older
                .map { "\($0.role.rawValue): \(truncated($0.content, to: 90))" }
                .joined(separator: "\n")
            items.append(
                ContextItem(
                    role: .system,
                    text: "earlier conversation, condensed (\(older.count) turns):\n\(digest)"))
        }
        for message in transcript.suffix(keepLast) {
            items.append(
                ContextItem(
                    role: message.role == .user ? .user : .assistant,
                    text: message.content))
        }
        return items
    }

    // MARK: Tree

    /// Serialized tree for the request context, collapsed only if over budget.
    static func treeContext(
        scenario: Scenario,
        focusedNodeId: String?,
        budgetBytes: Int
    ) -> String {
        let analytics = TreeAnalytics(
            tree: scenario.tree, realizedPath: scenario.realizedPath, unit: scenario.payoffUnit)
        let full = json(dictionary(for: scenario.tree))
        if full.utf8.count <= budgetBytes {
            return full
        }
        let focusPath: Set<String> =
            focusedNodeId.flatMap { Tree.path(scenario.tree, to: $0).map(Set.init) } ?? []
        return json(
            collapsedDictionary(
                node: scenario.tree, depth: 0, focusPath: focusPath, analytics: analytics))
    }

    /// A one-line position event when the user opened chat from a node (§2.3 #4)
    /// or marked a branch (§2.3).
    static func focusEvent(scenario: Scenario, focusedNodeId: String) -> ContextItem? {
        guard let node = Tree.find(scenario.tree, id: focusedNodeId) else { return nil }
        return ContextItem(
            role: .system,
            text: "user is asking about node \(node.id) (\"\(node.label)\")")
    }

    static func positionEvent(scenario: Scenario) -> ContextItem? {
        guard let currentId = scenario.realizedPath.last,
            let node = Tree.find(scenario.tree, id: currentId)
        else { return nil }
        return ContextItem(
            role: .system,
            text: "reality update: the realized branch is now \(node.id) (\"\(node.label)\")")
    }

    // MARK: - Internals

    private static func collapsedDictionary(
        node: Node, depth: Int, focusPath: Set<String>, analytics: TreeAnalytics
    ) -> [String: Any] {
        let keepExpanded = depth < collapseDepth || focusPath.contains(node.id)
        guard keepExpanded else {
            return stub(for: node, analytics: analytics)
        }
        var dict = dictionary(for: node, recurse: false)
        if let children = node.children, !children.isEmpty {
            dict["children"] = children.map {
                collapsedDictionary(
                    node: $0, depth: depth + 1, focusPath: focusPath, analytics: analytics)
            }
        }
        return dict
    }

    private static func stub(for node: Node, analytics: TreeAnalytics) -> [String: Any] {
        var stub: [String: Any] = [
            "id": node.id,
            "label": node.label,
            "p": node.p,
        ]
        if let ev = analytics[node.id]?.ev {
            stub["ev"] = ev
        }
        if !(node.children?.isEmpty ?? true) {
            stub["collapsed"] = true
        }
        return stub
    }

    private static func dictionary(for node: Node, recurse: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "id": node.id,
            "label": node.label,
            "p": node.p,
            "actor": node.actor.rawValue,
        ]
        if let sub = node.sub { dict["sub"] = sub }
        if let move = node.move { dict["move"] = move }
        if let note = node.note { dict["note"] = note }
        if let payoff = node.payoff {
            switch payoff {
            case .scalar(let value): dict["payoff"] = value
            case .components(let components): dict["payoff"] = components
            }
        }
        if let confidence = node.confidence { dict["confidence"] = confidence.rawValue }
        if node.reached == true { dict["reached"] = true }
        if recurse, let children = node.children, !children.isEmpty {
            dict["children"] = children.map { dictionary(for: $0) }
        }
        return dict
    }

    private static func json(_ dictionary: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dictionary, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
