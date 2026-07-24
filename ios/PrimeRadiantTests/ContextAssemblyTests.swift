import PrimeRadiantCore
import XCTest

@testable import PrimeRadiant

final class ContextAssemblyTests: XCTestCase {

    private func chain(depth: Int) -> Node {
        var node = Node(id: "d\(depth)", label: "leaf", p: 1, actor: .user, payoff: .scalar(10))
        for level in stride(from: depth - 1, through: 0, by: -1) {
            node = Node(id: "d\(level)", label: "level \(level)", p: 1, actor: .user, children: [node])
        }
        return node
    }

    private func scenario(tree: Node) -> Scenario {
        Scenario(
            id: "01J0TESTSCENARIO0000000000",
            title: "t", createdAt: Date(), updatedAt: Date(),
            payoffUnit: PayoffUnit(kind: .currency, label: "USD"),
            status: .modeling, tree: tree)
    }

    func testFullTreeWhenUnderBudget() {
        let context = ContextAssembly.treeContext(
            scenario: scenario(tree: chain(depth: 6)), focusedNodeId: nil,
            budgetBytes: 1_000_000)
        XCTAssertTrue(context.contains("\"id\":\"d6\""), "leaf should survive under budget")
    }

    func testCollapsesBelowDepthFourOverBudget() {
        let context = ContextAssembly.treeContext(
            scenario: scenario(tree: chain(depth: 6)), focusedNodeId: nil, budgetBytes: 10)
        // Depth-4 node becomes a {id,label,p,ev} stub: children below it vanish.
        XCTAssertTrue(context.contains("\"collapsed\":true"))
        XCTAssertFalse(context.contains("\"id\":\"d5\""))
        // Stubs still carry the client-computed EV (§5.3).
        XCTAssertTrue(context.contains("\"ev\":10"))
    }

    func testFocusSubtreeStaysExpandedOverBudget() {
        let context = ContextAssembly.treeContext(
            scenario: scenario(tree: chain(depth: 6)), focusedNodeId: "d6", budgetBytes: 10)
        XCTAssertTrue(context.contains("\"id\":\"d6\""), "focused subtree must stay expanded")
    }

    func testTranscriptDigestKeepsRecentVerbatim() {
        let messages = (0..<20).map {
            Message(role: $0 % 2 == 0 ? .user : .assistant, content: "turn \($0)", timestamp: Date())
        }
        let items = ContextAssembly.transcriptItems(messages, keepLast: 5)
        // 1 digest item + 5 verbatim.
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.first?.role, .system)
        XCTAssertTrue(items.first?.text.contains("15 turns") ?? false)
        XCTAssertEqual(items.last?.text, "turn 19")
    }
}
