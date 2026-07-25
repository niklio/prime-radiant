import Foundation
import PrimeRadiantCore

/// Scenario sync over SFTP to the paired box (pivot v3, replaces the
/// Cloudflare Worker client): the device remains the source of truth; the box
/// is the durable copy and the bridge to a future second device.
///
/// Layout on the box (paths relative to the home directory):
/// - `~/.prime-radiant/scenarios/<id>.json` — scenario JSON, ISO-8601 dates
/// - `~/.prime-radiant/trash/<id>.json`     — soft-deleted, with a deletedAt
///   stamp; restored by moving back; purged opportunistically after 30 days
///
/// Sync model (handoff §6, unchanged): push-on-change, pull-on-open,
/// last-write-wins on `updatedAt` in both directions.
actor BoxSync {

    private let box: any SSHBox
    /// Reconnect-on-drop hook (BoxSession.ensureConnected).
    private let ensureConnected: @Sendable () async -> Bool
    private var directoriesEnsured = false

    static let rootDir = ".prime-radiant"
    static let scenariosDir = ".prime-radiant/scenarios"
    static let trashDir = ".prime-radiant/trash"
    static let purgeAfterDays = 30

    enum PushResult: Sendable {
        case pushed
        /// The box copy was newer (LWW); adopt it locally.
        case superseded(Scenario)
    }

    enum SyncError: Error {
        case offline
        case decoding
    }

    /// Trash entry: the scenario plus its deletion stamp.
    struct TrashEntry: Codable, Sendable {
        var deletedAt: Date
        var scenario: Scenario
    }

    init(box: any SSHBox, ensureConnected: @escaping @Sendable () async -> Bool) {
        self.box = box
        self.ensureConnected = ensureConnected
    }

    // MARK: - Push / pull (LWW both directions)

    /// Push-on-change. If the box copy is newer, the box wins: it comes back
    /// for local adoption instead.
    func push(_ scenario: Scenario) async throws -> PushResult {
        try await prepare()
        let path = Self.scenarioPath(id: scenario.id)
        if let remoteData = try? await box.sftpRead(path: path),
            let remote = try? Self.decoder.decode(Scenario.self, from: remoteData),
            remote.updatedAt > scenario.updatedAt {
            return .superseded(remote)
        }
        try await box.sftpWrite(path: path, data: Self.encoder.encode(scenario))
        return .pushed
    }

    /// Pull-on-open: every scenario the box holds (callers LWW-merge against
    /// the local store). Undecodable files are skipped, never fatal.
    func pullAll() async throws -> [Scenario] {
        try await prepare()
        let names = try await box.sftpList(directory: Self.scenariosDir)
        var scenarios: [Scenario] = []
        for name in names where name.hasSuffix(".json") {
            guard
                let data = try? await box.sftpRead(path: "\(Self.scenariosDir)/\(name)"),
                let scenario = try? Self.decoder.decode(Scenario.self, from: data)
            else { continue }
            scenarios.append(scenario)
        }
        return scenarios
    }

    func pull(id: String) async throws -> Scenario? {
        try await prepare()
        guard let data = try? await box.sftpRead(path: Self.scenarioPath(id: id)) else {
            return nil
        }
        return try? Self.decoder.decode(Scenario.self, from: data)
    }

    // MARK: - Soft delete / restore / purge

    /// Soft delete: move the box copy into the trash with a deletedAt stamp.
    /// The local copy travels along in case the box never saw the latest.
    func softDelete(_ scenario: Scenario, at date: Date = Date()) async throws {
        try await prepare()
        let path = Self.scenarioPath(id: scenario.id)
        var latest = scenario
        if let remoteData = try? await box.sftpRead(path: path),
            let remote = try? Self.decoder.decode(Scenario.self, from: remoteData),
            remote.updatedAt > scenario.updatedAt {
            latest = remote
        }
        let entry = TrashEntry(deletedAt: date, scenario: latest)
        try await box.sftpWrite(
            path: Self.trashPath(id: scenario.id), data: Self.encoder.encode(entry))
        try? await box.sftpRemove(path: path)
    }

    /// Undo for the delete toast: move the trash entry back.
    func restore(id: String) async throws -> Scenario? {
        try await prepare()
        guard
            let data = try? await box.sftpRead(path: Self.trashPath(id: id)),
            let entry = try? Self.decoder.decode(TrashEntry.self, from: data)
        else { return nil }
        try await box.sftpWrite(
            path: Self.scenarioPath(id: id), data: Self.encoder.encode(entry.scenario))
        try? await box.sftpRemove(path: Self.trashPath(id: id))
        return entry.scenario
    }

    /// 30-day purge, done opportunistically by the app (there is no box-side
    /// component to run it — pivot v3).
    func purgeTrash(now: Date = Date()) async throws {
        try await prepare()
        let cutoff = now.addingTimeInterval(-Double(Self.purgeAfterDays) * 86_400)
        let names = try await box.sftpList(directory: Self.trashDir)
        for name in names where name.hasSuffix(".json") {
            let path = "\(Self.trashDir)/\(name)"
            guard
                let data = try? await box.sftpRead(path: path),
                let entry = try? Self.decoder.decode(TrashEntry.self, from: data)
            else { continue }
            if entry.deletedAt < cutoff {
                try? await box.sftpRemove(path: path)
            }
        }
    }

    // MARK: - Internals

    private func prepare() async throws {
        guard await ensureConnected() else { throw SyncError.offline }
        guard !directoriesEnsured else { return }
        try await box.sftpMkdir(path: Self.rootDir)
        try await box.sftpMkdir(path: Self.scenariosDir)
        try await box.sftpMkdir(path: Self.trashDir)
        directoriesEnsured = true
    }

    static func scenarioPath(id: String) -> String {
        "\(scenariosDir)/\(id).json"
    }

    static func trashPath(id: String) -> String {
        "\(trashDir)/\(id).json"
    }

    /// Wire dates as ISO-8601 with fractional seconds (matches StoredScenario).
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }()
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = isoFormatter.date(from: string) ?? isoBasicFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid ISO-8601 date: \(string)")
        }
    }
}

// ISO8601DateFormatter is documented thread-safe; Sendable annotation only lags.
private nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private nonisolated(unsafe) let isoBasicFormatter = ISO8601DateFormatter()
