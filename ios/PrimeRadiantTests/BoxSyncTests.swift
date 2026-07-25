import PrimeRadiantCore
import XCTest

@testable import PrimeRadiant

/// BoxSync over the FakeBox SFTP filesystem: directory bootstrap, LWW in both
/// directions, soft-delete to trash with a deletedAt stamp, restore, and the
/// opportunistic 30-day purge.
final class BoxSyncTests: XCTestCase {

    private func makeSync(_ box: FakeBox) -> BoxSync {
        BoxSync(box: box, ensureConnected: { true })
    }

    private func scenario(
        id: String = "01J0SYNCSCENARI0000000001", updatedAt: Date
    ) -> Scenario {
        Scenario(
            id: id,
            title: "test",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: updatedAt,
            payoffUnit: PayoffUnit(kind: .currency, label: "USD"),
            status: .modeling,
            tree: Node(id: "root-\(id)", label: "root", p: 1, actor: .user))
    }

    // MARK: Push (LWW: box wins only when newer)

    func testFirstPushCreatesDirectoriesAndWrites() async throws {
        let box = FakeBox()
        let sync = makeSync(box)
        let local = scenario(updatedAt: Date(timeIntervalSince1970: 100))

        let result = try await sync.push(local)

        guard case .pushed = result else { return XCTFail("expected pushed") }
        XCTAssertTrue(box.directories.isSuperset(of: [
            ".prime-radiant", ".prime-radiant/scenarios", ".prime-radiant/trash",
        ]))
        let stored = box.files[BoxSync.scenarioPath(id: local.id)]
        XCTAssertNotNil(stored)
        let decoded = try BoxSync.decoder.decode(Scenario.self, from: stored!)
        XCTAssertEqual(decoded, local)
    }

    func testPushIsSupersededByNewerBoxCopy() async throws {
        let box = FakeBox()
        let sync = makeSync(box)
        let older = scenario(updatedAt: Date(timeIntervalSince1970: 100))
        var newer = older
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        newer.title = "box edit"
        _ = try await sync.push(newer)

        let result = try await sync.push(older)

        guard case .superseded(let fromBox) = result else {
            return XCTFail("expected superseded")
        }
        XCTAssertEqual(fromBox.title, "box edit")
        // The stale local copy never overwrote the box.
        let stored = try BoxSync.decoder.decode(
            Scenario.self, from: box.files[BoxSync.scenarioPath(id: older.id)]!)
        XCTAssertEqual(stored.updatedAt, newer.updatedAt)
    }

    func testPushOverwritesOlderBoxCopy() async throws {
        let box = FakeBox()
        let sync = makeSync(box)
        let older = scenario(updatedAt: Date(timeIntervalSince1970: 100))
        _ = try await sync.push(older)
        var newer = older
        newer.updatedAt = Date(timeIntervalSince1970: 200)

        let result = try await sync.push(newer)

        guard case .pushed = result else { return XCTFail("expected pushed") }
        let stored = try BoxSync.decoder.decode(
            Scenario.self, from: box.files[BoxSync.scenarioPath(id: older.id)]!)
        XCTAssertEqual(stored.updatedAt, newer.updatedAt)
    }

    // MARK: Pull

    func testPullAllDecodesScenariosAndSkipsGarbage() async throws {
        let box = FakeBox()
        let sync = makeSync(box)
        let one = scenario(id: "01J0SYNCSCENARI0000000001", updatedAt: Date(timeIntervalSince1970: 50))
        let two = scenario(id: "01J0SYNCSCENARI0000000002", updatedAt: Date(timeIntervalSince1970: 60))
        _ = try await sync.push(one)
        _ = try await sync.push(two)
        box.files["\(BoxSync.scenariosDir)/garbage.json"] = Data("not json".utf8)

        let pulled = try await sync.pullAll()
        XCTAssertEqual(Set(pulled.map(\.id)), [one.id, two.id])
    }

    // MARK: Soft delete / restore / purge

    func testSoftDeleteMovesToTrashWithStamp() async throws {
        let box = FakeBox()
        let sync = makeSync(box)
        let local = scenario(updatedAt: Date(timeIntervalSince1970: 100))
        _ = try await sync.push(local)

        let deletedAt = Date(timeIntervalSince1970: 500)
        try await sync.softDelete(local, at: deletedAt)

        XCTAssertNil(box.files[BoxSync.scenarioPath(id: local.id)])
        let entryData = box.files[BoxSync.trashPath(id: local.id)]
        XCTAssertNotNil(entryData)
        let entry = try BoxSync.decoder.decode(BoxSync.TrashEntry.self, from: entryData!)
        XCTAssertEqual(entry.deletedAt, deletedAt)
        XCTAssertEqual(entry.scenario, local)
    }

    func testRestoreMovesBackFromTrash() async throws {
        let box = FakeBox()
        let sync = makeSync(box)
        let local = scenario(updatedAt: Date(timeIntervalSince1970: 100))
        _ = try await sync.push(local)
        try await sync.softDelete(local, at: Date(timeIntervalSince1970: 500))

        let restored = try await sync.restore(id: local.id)

        XCTAssertEqual(restored, local)
        XCTAssertNil(box.files[BoxSync.trashPath(id: local.id)])
        XCTAssertNotNil(box.files[BoxSync.scenarioPath(id: local.id)])
    }

    func testPurgeRemovesOnlyEntriesOlderThanThirtyDays() async throws {
        let box = FakeBox()
        let sync = makeSync(box)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let old = scenario(id: "01J0SYNCSCENARI00000000LD", updatedAt: now)
        let fresh = scenario(id: "01J0SYNCSCENARI0000000FRE", updatedAt: now)
        _ = try await sync.push(old)
        _ = try await sync.push(fresh)
        try await sync.softDelete(old, at: now.addingTimeInterval(-31 * 86_400))
        try await sync.softDelete(fresh, at: now.addingTimeInterval(-1 * 86_400))

        try await sync.purgeTrash(now: now)

        XCTAssertNil(box.files[BoxSync.trashPath(id: old.id)])
        XCTAssertNotNil(box.files[BoxSync.trashPath(id: fresh.id)])
    }

    // MARK: Offline

    func testOfflineBoxThrowsWithoutTouchingSFTP() async {
        let box = FakeBox()
        let sync = BoxSync(box: box, ensureConnected: { false })

        do {
            _ = try await sync.push(scenario(updatedAt: Date()))
            XCTFail("expected offline error")
        } catch {
            XCTAssertTrue(box.log.isEmpty, "offline push still touched the box: \(box.log)")
        }
    }
}
