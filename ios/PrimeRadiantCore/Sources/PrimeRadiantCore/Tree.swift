import Foundation

/// Value-semantic traversal and mutation helpers over the recursive `Node` tree.
public enum Tree {

    /// Depth-first pre-order walk.
    public static func forEach(_ root: Node, _ body: (Node) -> Void) {
        body(root)
        for child in root.children ?? [] { forEach(child, body) }
    }

    public static func find(_ root: Node, id: String) -> Node? {
        if root.id == id { return root }
        for child in root.children ?? [] {
            if let hit = find(child, id: id) { return hit }
        }
        return nil
    }

    public static func contains(_ root: Node, id: String) -> Bool {
        find(root, id: id) != nil
    }

    /// Ids on the path root→target inclusive, or nil if absent.
    public static func path(_ root: Node, to id: String) -> [String]? {
        if root.id == id { return [root.id] }
        for child in root.children ?? [] {
            if let sub = path(child, to: id) { return [root.id] + sub }
        }
        return nil
    }

    /// Parent of `id`, or nil for the root / absent id.
    public static func parent(_ root: Node, of id: String) -> Node? {
        for child in root.children ?? [] {
            if child.id == id { return root }
            if let hit = parent(child, of: id) { return hit }
        }
        return nil
    }

    public static func allIds(_ root: Node) -> [String] {
        var ids: [String] = []
        forEach(root) { ids.append($0.id) }
        return ids
    }

    public static func count(_ root: Node) -> Int {
        var n = 0
        forEach(root) { _ in n += 1 }
        return n
    }

    /// Returns a copy with `transform` applied to the node with `id`.
    /// Returns nil if the id is absent (caller decides whether that's an error).
    public static func updating(_ root: Node, id: String, _ transform: (inout Node) -> Void) -> Node? {
        var copy = root
        if copy.id == id {
            transform(&copy)
            return copy
        }
        guard let children = copy.children else { return nil }
        for (index, child) in children.enumerated() {
            if let updated = updating(child, id: id, transform) {
                copy.children?[index] = updated
                return copy
            }
        }
        return nil
    }

    /// Returns a copy with the node `id` removed, or nil if absent or if `id` is the root.
    public static func removing(_ root: Node, id: String) -> Node? {
        guard root.id != id else { return nil }
        var copy = root
        guard let children = copy.children else { return nil }
        if children.contains(where: { $0.id == id }) {
            copy.children = children.filter { $0.id != id }
            return copy
        }
        for (index, child) in children.enumerated() {
            if let updated = removing(child, id: id) {
                copy.children?[index] = updated
                return copy
            }
        }
        return nil
    }

    /// Sibling probabilities renormalized to sum to 1 throughout the tree.
    /// A sibling group summing to 0 splits mass uniformly. The root's p becomes 1.
    public static func renormalized(_ root: Node) -> Node {
        var copy = root
        copy.p = 1
        renormalizeChildren(&copy)
        return copy
    }

    private static func renormalizeChildren(_ node: inout Node) {
        guard var children = node.children, !children.isEmpty else { return }
        let total = children.reduce(0) { $0 + max(0, $1.p) }
        for index in children.indices {
            children[index].p = total > 0 ? max(0, children[index].p) / total : 1.0 / Double(children.count)
            renormalizeChildren(&children[index])
        }
        node.children = children
    }
}
