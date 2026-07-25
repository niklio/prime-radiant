import Foundation
import PrimeRadiantCore

/// The sync surface RootView drives (push-on-change, pull-on-open, LWW).
/// Implemented by the SFTP `BoxSync` (SSH fallback) and `GatewaySync`
/// (/v1/scenarios, the primary after provisioning); `RoutedSync` picks per the
/// transport ladder.
protocol ScenarioSyncing: Sendable {
    func push(_ scenario: Scenario) async throws -> BoxSync.PushResult
    func pullAll() async throws -> [Scenario]
    func pull(id: String) async throws -> Scenario?
    func softDelete(_ scenario: Scenario, at date: Date) async throws
    func restore(id: String) async throws -> Scenario?
    func purgeTrash(now: Date) async throws
}

extension ScenarioSyncing {
    func softDelete(_ scenario: Scenario) async throws {
        try await softDelete(scenario, at: Date())
    }

    func purgeTrash() async throws {
        try await purgeTrash(now: Date())
    }
}

/// BoxSync's own signatures already match the protocol exactly.
extension BoxSync: ScenarioSyncing {}

/// Scenario sync over the gateway's /v1/scenarios CRUD (server/gateway):
/// PUT with LWW (409 = stale → adopt the server copy), soft DELETE with
/// 30-day purge server-side, POST /restore for the undo toast. The gateway
/// runs its own nightly backups and purge — `purgeTrash` is server business.
struct GatewaySync: ScenarioSyncing {
    let gateway: any GatewayAPI
    let base: URL
    let token: String

    func push(_ scenario: Scenario) async throws -> BoxSync.PushResult {
        let body = try BoxSync.encoder.encode(scenario)
        let (status, _) = try await gateway.request(
            base: base, token: token, method: "PUT",
            path: "v1/scenarios/\(scenario.id)", body: body)
        switch status {
        case 200:
            return .pushed
        case 409:
            // Stale write: the server copy is newer — pull and adopt it.
            if let newer = try await pull(id: scenario.id) {
                return .superseded(newer)
            }
            return .pushed
        default:
            throw GatewayError.status(status)
        }
    }

    func pullAll() async throws -> [Scenario] {
        let (status, data) = try await gateway.request(
            base: base, token: token, method: "GET", path: "v1/scenarios", body: nil)
        guard status == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = object["scenarios"] as? [[String: Any]]
        else { throw GatewayError.status(status) }
        var scenarios: [Scenario] = []
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if let scenario = (try? await pull(id: id)) ?? nil {
                scenarios.append(scenario)
            }
        }
        return scenarios
    }

    func pull(id: String) async throws -> Scenario? {
        let (status, data) = try await gateway.request(
            base: base, token: token, method: "GET", path: "v1/scenarios/\(id)", body: nil)
        guard status == 200 else { return nil }
        return try? BoxSync.decoder.decode(Scenario.self, from: data)
    }

    func softDelete(_ scenario: Scenario, at date: Date) async throws {
        _ = try await gateway.request(
            base: base, token: token, method: "DELETE",
            path: "v1/scenarios/\(scenario.id)", body: nil)
    }

    func restore(id: String) async throws -> Scenario? {
        let (status, _) = try await gateway.request(
            base: base, token: token, method: "POST",
            path: "v1/scenarios/\(id)/restore", body: nil)
        guard status == 200 else { return nil }
        return try await pull(id: id)
    }

    func purgeTrash(now: Date) async throws {
        // The gateway's in-process job purges 30-day-old soft deletes itself.
    }
}

/// Gateway-first routing with the SFTP path as fallback when the gateway is
/// unreachable but SSH still answers (server/README hybrid posture).
struct RoutedSync: ScenarioSyncing {
    let transport: @MainActor @Sendable () -> ActiveTransport
    let gatewaySync: @MainActor @Sendable () -> GatewaySync?
    let sshSync: BoxSync
    let onGatewayFailure: @MainActor @Sendable () -> Void

    private func route() async -> (any ScenarioSyncing)? {
        switch await transport() {
        case .gateway:
            if let gateway = await gatewaySync() { return gateway }
            return sshSync
        case .ssh:
            return sshSync
        case .offline:
            return nil
        }
    }

    private func run<T: Sendable>(
        _ operation: @Sendable (any ScenarioSyncing) async throws -> T
    ) async throws -> T {
        guard let primary = await route() else { throw BoxSync.SyncError.offline }
        if primary is GatewaySync {
            do {
                return try await operation(primary)
            } catch let error as GatewayError {
                await onGatewayFailure()
                // Quiet fallback: SFTP still works while SSH answers.
                _ = error
                return try await operation(sshSync)
            }
        }
        return try await operation(primary)
    }

    func push(_ scenario: Scenario) async throws -> BoxSync.PushResult {
        try await run { try await $0.push(scenario) }
    }

    func pullAll() async throws -> [Scenario] {
        try await run { try await $0.pullAll() }
    }

    func pull(id: String) async throws -> Scenario? {
        try await run { try await $0.pull(id: id) }
    }

    func softDelete(_ scenario: Scenario, at date: Date) async throws {
        try await run { try await $0.softDelete(scenario, at: date) }
    }

    func restore(id: String) async throws -> Scenario? {
        try await run { try await $0.restore(id: id) }
    }

    func purgeTrash(now: Date) async throws {
        try await run { try await $0.purgeTrash(now: now) }
    }
}
