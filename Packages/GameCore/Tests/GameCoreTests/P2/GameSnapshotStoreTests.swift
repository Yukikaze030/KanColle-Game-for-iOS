import Foundation
import SQLite3
import XCTest
@testable import GameCore

final class GameSnapshotStoreTests: XCTestCase {
    private struct State: Codable, Equatable, Sendable { let name: String; let ships: [Int] }
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: $0.path)
            try? FileManager.default.removeItem(at: $0)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    func testEmptyDatabaseCreatesSchema() throws {
        let url = databaseURL()
        let store = try GameSnapshotStore(path: url.path)
        let restored: RestoredGameSnapshot<State>? = try store.restore(State.self, staleAfter: 60)
        XCTAssertNil(restored)
        XCTAssertEqual(try queryInt(path: url.path, sql: "SELECT version FROM schema_meta"), 1)
    }

    func testSaveReadAndOverwriteRevisionAtomically() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = try GameSnapshotStore(path: databaseURL().path)
        try store.save(state: State(name: "old", ships: [1]), revision: 1, updatedAt: now,
                       timers: [timer("old", now.addingTimeInterval(50), 1)])
        try store.save(state: State(name: "new", ships: [2, 3]), revision: 2, updatedAt: now,
                       timers: [timer("new", now.addingTimeInterval(100), 2)])
        let restored = try XCTUnwrap(store.restore(State.self, staleAfter: 60, now: now))
        XCTAssertEqual(restored.revision, 2)
        XCTAssertEqual(restored.state, State(name: "new", ships: [2, 3]))
        XCTAssertTrue(restored.isRestored)
        XCTAssertFalse(restored.isStale)
        XCTAssertEqual(try store.timers(now: now).map(\.id), ["new"])
    }

    func testRevisionRegressionIsRejectedWithoutMutation() throws {
        let store = try GameSnapshotStore(path: databaseURL().path)
        try store.save(state: State(name: "current", ships: []), revision: 10)
        XCTAssertThrowsError(try store.save(state: State(name: "old", ships: []), revision: 9)) {
            XCTAssertEqual($0 as? GameSnapshotStore.StoreError, .revisionRegression(current: 10, attempted: 9))
        }
        XCTAssertEqual(try store.restore(State.self, staleAfter: 60)?.state.name, "current")
    }

    func testInjectedFailureRollsBackWholeTransaction() throws {
        let url = databaseURL()
        do {
            let store = try GameSnapshotStore(path: url.path)
            try store.save(state: State(name: "baseline", ships: [1]), revision: 1,
                           timers: [timer("baseline", Date().addingTimeInterval(100), 1)])
        }
        let store = try GameSnapshotStore(path: url.path, failureInjector: { $0 == .afterCurrentSnapshot })
        XCTAssertThrowsError(try store.save(state: State(name: "partial", ships: [2]), revision: 2)) {
            XCTAssertEqual($0 as? GameSnapshotStore.StoreError, .injectedFailure(.afterCurrentSnapshot))
        }
        XCTAssertEqual(try store.restore(State.self, staleAfter: 60)?.revision, 1)
        XCTAssertEqual(try store.timers().map(\.id), ["baseline"])
    }

    func testConcurrentTwentySavesEndAtMaximumRevisionWithoutBusyLeak() throws {
        let store = try GameSnapshotStore(path: databaseURL().path)
        let group = DispatchGroup(), queue = DispatchQueue(label: "snapshot.concurrent", attributes: .concurrent)
        let errors = LockedErrors()
        for revision in 1...20 {
            group.enter(); queue.async {
                defer { group.leave() }
                do { try store.save(state: State(name: "r\(revision)", ships: [revision]), revision: Int64(revision)) }
                catch let error as GameSnapshotStore.StoreError {
                    if case .revisionRegression = error { return }
                    errors.append(error)
                } catch { errors.append(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        XCTAssertEqual(try store.restore(State.self, staleAfter: 60)?.revision, 20)
    }

    func testCorruptPayloadIsIsolatedAsTypedError() throws {
        let url = databaseURL(), store = try GameSnapshotStore(path: url.path)
        try store.save(state: State(name: "valid", ships: []), revision: 1)
        try execute(path: url.path, sql: "UPDATE current_snapshot SET state_json=x'FFFF' WHERE id=1")
        XCTAssertThrowsError(try store.restore(State.self, staleAfter: 60)) {
            guard case .corruptPayload = $0 as? GameSnapshotStore.StoreError else { return XCTFail("\($0)") }
        }
    }

    func testTooNewSchemaAndCorruptDatabaseAreTyped() throws {
        let newURL = databaseURL()
        try execute(path: newURL.path, sql: "CREATE TABLE schema_meta(version INTEGER NOT NULL); INSERT INTO schema_meta VALUES(99)")
        XCTAssertThrowsError(try GameSnapshotStore(path: newURL.path)) {
            XCTAssertEqual($0 as? GameSnapshotStore.StoreError, .schemaTooNew(found: 99, supported: 1))
        }
        let corruptURL = databaseURL(); try Data("not sqlite".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try GameSnapshotStore(path: corruptURL.path)) {
            guard case .corruptDatabase = $0 as? GameSnapshotStore.StoreError else { return XCTFail("\($0)") }
        }
    }

    func testReadOnlyDirectoryAndUnopenablePathAreTyped() throws {
        let directory = temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try GameSnapshotStore(path: directory.appendingPathComponent("db.sqlite").path)) {
            guard case .readOnly = $0 as? GameSnapshotStore.StoreError else { return XCTFail("\($0)") }
        }
        let missing = temporaryDirectory().appendingPathComponent("missing/db.sqlite")
        XCTAssertThrowsError(try GameSnapshotStore(path: missing.path)) {
            guard case .open = $0 as? GameSnapshotStore.StoreError else { return XCTFail("\($0)") }
        }
    }

    func testStaleRestoreCanBeReplacedByFreshPortRevision() throws {
        let store = try GameSnapshotStore(path: databaseURL().path), old = Date(timeIntervalSince1970: 1_000)
        try store.save(state: State(name: "stale", ships: []), revision: 1, updatedAt: old)
        let stale = try XCTUnwrap(store.restore(State.self, staleAfter: 60, now: old.addingTimeInterval(61)))
        XCTAssertTrue(stale.isRestored); XCTAssertTrue(stale.isStale)
        let fresh = old.addingTimeInterval(62)
        try store.save(state: State(name: "port", ships: [7]), revision: 2, updatedAt: fresh)
        XCTAssertFalse(try XCTUnwrap(store.restore(State.self, staleAfter: 60, now: fresh)).isStale)
    }

    func testTimersSortFilterAndCleanupDoesNotDeleteSnapshot() throws {
        let now = Date(timeIntervalSince1970: 10_000), store = try GameSnapshotStore(path: databaseURL().path)
        try store.save(state: State(name: "keep", ships: []), revision: 3, updatedAt: now, timers: [
            timer("future-b", now.addingTimeInterval(20), 3), timer("expired", now.addingTimeInterval(-101), 3),
            timer("future-a", now.addingTimeInterval(10), 3), timer("cancelled", now.addingTimeInterval(5), 3, true)
        ])
        XCTAssertEqual(try store.timers(now: now, clearlyExpiredAfter: 100).map(\.id), ["future-a", "future-b"])
        XCTAssertEqual(try store.removeExpiredTimers(before: now), 1)
        XCTAssertEqual(try store.restore(State.self, staleAfter: 60, now: now)?.revision, 3)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotTests-\(UUID())", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url); return url
    }
    private func databaseURL() -> URL { temporaryDirectory().appendingPathComponent("snapshot.sqlite") }
    private func timer(_ id: String, _ date: Date, _ revision: Int64, _ cancelled: Bool = false) -> GameTimer {
        GameTimer(id: id, kind: .expedition, slot: 1, title: id, detail: "detail", completionDate: date,
                  sourceRevision: revision, isCancelled: cancelled)
    }
    private func execute(path: String, sql: String) throws {
        var db: OpaquePointer?; guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    private func queryInt(path: String, sql: String) throws -> Int {
        var db: OpaquePointer?; guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Error] = []
    var values: [Error] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ error: Error) { lock.lock(); storage.append(error); lock.unlock() }
}
