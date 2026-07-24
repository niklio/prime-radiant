import Foundation
import PrimeRadiantCore
import SwiftData

/// SwiftData wrapper around the canonical codable `Scenario` (handoff §4): the
/// JSON blob is the single source of truth locally and the exact body PUT to the
/// sync Worker; the mirrored columns exist for querying and LWW comparison only.
@Model
final class StoredScenario {
    @Attribute(.unique) var id: String
    var title: String
    var status: String
    var updatedAt: Date
    /// Archive is client-side state (§2.2); the Worker only knows delete.
    var archivedAt: Date?
    /// Local mirror of the server's soft delete, kept for the undo toast.
    var deletedAt: Date?
    var body: Data

    init(scenario: Scenario) throws {
        self.id = scenario.id
        self.title = scenario.title
        self.status = scenario.status.rawValue
        self.updatedAt = scenario.updatedAt
        self.body = try Self.encode(scenario)
    }

    func update(from scenario: Scenario) throws {
        title = scenario.title
        status = scenario.status.rawValue
        updatedAt = scenario.updatedAt
        body = try Self.encode(scenario)
    }

    func decoded() -> Scenario? {
        try? Self.decoder.decode(Scenario.self, from: body)
    }

    private static func encode(_ scenario: Scenario) throws -> Data {
        try encoder.encode(scenario)
    }

    /// Same wire format the Worker validates (ISO-8601 timestamps).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }()
}
