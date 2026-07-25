import Foundation
import Observation

/// The transport ladder (hybrid posture, server/README): after provisioning the
/// app prefers the gateway (HTTP+SSE over the tailnet); SSH remains the repair
/// channel and transport fallback; neither reachable → the existing quiet
/// read-only state. Health-gated on app foreground:
///
///   /v1/health ok            → gateway  (budget "resting" → status line)
///   health fails, SSH up     → one `launchctl kickstart` repair, re-probe;
///                              still down → ssh, quietly
///   both down                → offline (read-only)
///
/// Pure selection logic behind injected probes so the ladder is unit-tested
/// with fakes — no live gateway, no live box.
enum ActiveTransport: Equatable, Sendable {
    case gateway
    case ssh
    case offline
}

@MainActor
@Observable
final class TransportController {

    private(set) var transport: ActiveTransport = .offline
    /// The gateway reported budget "resting" — feeds the existing
    /// "the radiant rests until the cycle renews" status line.
    private(set) var budgetResting = false

    /// nil when no gateway is configured for the paired box.
    private let health: @MainActor () async -> GatewayHealth?
    private let hasGateway: @MainActor () -> Bool
    private let sshEnsure: @MainActor () async -> Bool
    /// One-shot repair over SSH (`launchctl kickstart -k gui/$UID/com.primeradiant.gateway`).
    private let sshRepair: @MainActor () async -> Bool

    init(
        hasGateway: @escaping @MainActor () -> Bool,
        health: @escaping @MainActor () async -> GatewayHealth?,
        sshEnsure: @escaping @MainActor () async -> Bool,
        sshRepair: @escaping @MainActor () async -> Bool
    ) {
        self.hasGateway = hasGateway
        self.health = health
        self.sshEnsure = sshEnsure
        self.sshRepair = sshRepair
    }

    /// The ladder, run on app foreground and after pairing changes.
    @discardableResult
    func refresh() async -> ActiveTransport {
        guard hasGateway() else {
            transport = await sshEnsure() ? .ssh : .offline
            budgetResting = false
            return transport
        }
        if let report = await health() {
            adopt(gateway: report)
            return transport
        }
        // Gateway dark. If SSH answers, try one quiet kickstart repair.
        guard await sshEnsure() else {
            transport = .offline
            budgetResting = false
            return transport
        }
        if await sshRepair(), let report = await health() {
            adopt(gateway: report)
            return transport
        }
        // Repair didn't take — ride SSH quietly.
        transport = .ssh
        budgetResting = false
        return transport
    }

    private func adopt(gateway report: GatewayHealth) {
        transport = .gateway
        budgetResting = report.budget == "resting"
    }

    /// Chat streams report budget state in-band ({"error":"budget_resting"}).
    func noteBudgetResting(_ resting: Bool) {
        budgetResting = resting
    }

    /// A gateway call failed mid-flight: drop to SSH until the next health gate.
    func noteGatewayFailure() {
        if transport == .gateway { transport = .ssh }
    }
}

/// The standing repair command (server/README operations crib).
enum GatewayRepair {
    static let kickstartCommand =
        "launchctl kickstart -k \"gui/$(id -u)/com.primeradiant.gateway\""
}
