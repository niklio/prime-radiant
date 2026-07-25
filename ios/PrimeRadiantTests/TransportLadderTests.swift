import XCTest

@testable import PrimeRadiant

/// The transport selection ladder (server/README hybrid posture) with fakes:
/// gateway ok / gateway down + ssh ok (one repair attempt) / both down, plus
/// the budget-resting passthrough and the no-gateway configuration.
@MainActor
final class TransportLadderTests: XCTestCase {

    private final class Probe {
        var healthResults: [GatewayHealth?] = []
        var healthCalls = 0
        var sshUp = false
        var repairCalls = 0
        var repairSucceeds = false
        var repairHeals = false

        func nextHealth() -> GatewayHealth? {
            healthCalls += 1
            if healthResults.isEmpty { return nil }
            return healthResults.removeFirst()
        }
    }

    private func makeController(
        _ probe: Probe, hasGateway: Bool = true
    ) -> TransportController {
        TransportController(
            hasGateway: { hasGateway },
            health: { probe.nextHealth() },
            sshEnsure: { probe.sshUp },
            sshRepair: {
                probe.repairCalls += 1
                if probe.repairSucceeds && probe.repairHeals {
                    probe.healthResults = [Self.okHealth()]
                }
                return probe.repairSucceeds
            })
    }

    private static func okHealth(budget: String = "ok") -> GatewayHealth {
        GatewayHealth(ok: true, version: "0.1.0", paired: true, agentReady: true, budget: budget)
    }

    func testGatewayHealthyWinsTheLadder() async {
        let probe = Probe()
        probe.healthResults = [Self.okHealth()]
        let controller = makeController(probe)

        let transport = await controller.refresh()

        XCTAssertEqual(transport, .gateway)
        XCTAssertFalse(controller.budgetResting)
        XCTAssertEqual(probe.repairCalls, 0, "no repair when the gateway answers")
    }

    func testBudgetRestingSurfacesFromHealth() async {
        let probe = Probe()
        probe.healthResults = [Self.okHealth(budget: "resting")]
        let controller = makeController(probe)

        _ = await controller.refresh()

        XCTAssertEqual(controller.transport, .gateway)
        XCTAssertTrue(controller.budgetResting, "resting budget → the standing status line")
    }

    func testGatewayDownSSHUpRepairsOnceThenFallsBackToSSH() async {
        let probe = Probe()
        probe.sshUp = true
        probe.repairSucceeds = true
        probe.repairHeals = false  // kickstart ran but the gateway stayed dark
        let controller = makeController(probe)

        let transport = await controller.refresh()

        XCTAssertEqual(transport, .ssh, "gateway dark after repair → ride SSH quietly")
        XCTAssertEqual(probe.repairCalls, 1, "exactly one kickstart attempt")
    }

    func testRepairHealsTheGateway() async {
        let probe = Probe()
        probe.sshUp = true
        probe.repairSucceeds = true
        probe.repairHeals = true
        let controller = makeController(probe)

        let transport = await controller.refresh()

        XCTAssertEqual(transport, .gateway, "post-kickstart health succeeds → gateway")
        XCTAssertEqual(probe.repairCalls, 1)
    }

    func testBothDownIsOffline() async {
        let probe = Probe()
        probe.sshUp = false
        let controller = makeController(probe)

        let transport = await controller.refresh()

        XCTAssertEqual(transport, .offline, "neither transport → the quiet read-only state")
        XCTAssertEqual(probe.repairCalls, 0, "no SSH → no repair attempt")
    }

    func testNoGatewayConfiguredRidesSSHDirectly() async {
        let probe = Probe()
        probe.sshUp = true
        let controller = makeController(probe, hasGateway: false)

        let transport = await controller.refresh()

        XCTAssertEqual(transport, .ssh)
        XCTAssertEqual(probe.healthCalls, 0, "no gateway config → no probe")
    }

    func testMidFlightGatewayFailureDropsToSSH() async {
        let probe = Probe()
        probe.healthResults = [Self.okHealth()]
        let controller = makeController(probe)
        _ = await controller.refresh()
        XCTAssertEqual(controller.transport, .gateway)

        controller.noteGatewayFailure()

        XCTAssertEqual(controller.transport, .ssh, "quiet fallback until the next health gate")
    }
}
