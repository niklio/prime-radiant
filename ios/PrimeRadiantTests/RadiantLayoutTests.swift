import PrimeRadiantCore
import XCTest

@testable import PrimeRadiant

/// Unit tests for the pure §3 radial-sector layout. Tree math itself is tested
/// in PrimeRadiantCore; these cover only the layout algorithm.
final class RadiantLayoutTests: XCTestCase {

    private func node(
        _ id: String, p: Double, children: [Node]? = nil
    ) -> Node {
        Node(id: id, label: id, p: p, actor: .user, children: children)
    }

    private var config: RadiantLayout.Config { RadiantLayout.Config() }

    func testRootAtOrigin() {
        let tree = node("root", p: 1, children: [node("a", p: 1)])
        let targets = RadiantLayout.targets(tree: tree, selectedId: nil)
        XCTAssertEqual(targets["root"], RadiantLayout.Vector3(x: 0, y: 0, z: 0))
    }

    func testEveryNodeHasATarget() {
        let tree = node(
            "root", p: 1,
            children: [
                node("a", p: 0.5, children: [node("a1", p: 1)]),
                node("b", p: 0.5),
            ])
        let targets = RadiantLayout.targets(tree: tree, selectedId: nil)
        XCTAssertEqual(Set(targets.keys), Set(["root", "a", "a1", "b"]))
    }

    func testSectorSpansSumToParentSpan() {
        let children = [node("a", p: 0.2), node("b", p: 0.5), node("c", p: 0.3)]
        let spans = RadiantLayout.sectorSpans(
            children: children, parentSpan: 2.0, selectionPath: [], config: config)
        XCTAssertEqual(spans.reduce(0, +), 2.0, accuracy: 1e-9)
    }

    func testSectorsProportionalToProbabilityWithoutSelection() {
        let children = [node("a", p: 0.75), node("b", p: 0.25)]
        let spans = RadiantLayout.sectorSpans(
            children: children, parentSpan: 1.0, selectionPath: [], config: config)
        XCTAssertEqual(spans[0], 0.75, accuracy: 1e-9)
        XCTAssertEqual(spans[1], 0.25, accuracy: 1e-9)
    }

    func testMinWidthFloorHolds() {
        // 0.01 raw share must be floored to ≥ 0.09 of the parent span (§3).
        let children = [node("a", p: 0.99), node("b", p: 0.01)]
        let spans = RadiantLayout.sectorSpans(
            children: children, parentSpan: 1.0, selectionPath: [], config: config)
        XCTAssertGreaterThanOrEqual(spans[1], 0.09 / (0.99 + 0.09))
        XCTAssertEqual(spans.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testSelectionReweightingBoostsOnPathChild() {
        let children = [node("a", p: 0.5), node("b", p: 0.5)]
        let neutral = RadiantLayout.sectorSpans(
            children: children, parentSpan: 1.0, selectionPath: [], config: config)
        let selected = RadiantLayout.sectorSpans(
            children: children, parentSpan: 1.0, selectionPath: ["a"], config: config)
        XCTAssertGreaterThan(selected[0], neutral[0])
        XCTAssertLessThan(selected[1], neutral[1])
        // ×3.2 vs ×0.5 on equal probabilities → 3.2 / 3.7 share.
        XCTAssertEqual(selected[0], 3.2 / 3.7, accuracy: 1e-9)
    }

    func testZeroProbabilityGroupSplitsUniformly() {
        let children = [node("a", p: 0), node("b", p: 0)]
        let spans = RadiantLayout.sectorSpans(
            children: children, parentSpan: 1.0, selectionPath: [], config: config)
        XCTAssertEqual(spans[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(spans[1], 0.5, accuracy: 1e-9)
    }

    func testDepthMapsToRadiusAndHeight() {
        let shallow = RadiantLayout.position(depth: 1, angle: 0, config: config)
        let deep = RadiantLayout.position(depth: 3, angle: 0, config: config)
        XCTAssertGreaterThan(deep.y, shallow.y)
        XCTAssertLessThan(deep.z, shallow.z)  // recedes into the fog
    }

    func testDeterministic() {
        let tree = node(
            "root", p: 1,
            children: [node("a", p: 0.6), node("b", p: 0.4)])
        let first = RadiantLayout.targets(tree: tree, selectedId: "a")
        let second = RadiantLayout.targets(tree: tree, selectedId: "a")
        XCTAssertEqual(first, second)
    }
}
