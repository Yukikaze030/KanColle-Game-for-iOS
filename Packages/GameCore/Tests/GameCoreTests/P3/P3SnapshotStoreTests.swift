import Foundation
import SQLite3
import XCTest
@testable import GameCore

final class P3SnapshotStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories = []
        super.tearDown()
    }

    func testCreatesSchemaInWALModeAndRoundTripsSnapshot() throws {
        let url = databaseURL()
        let store = try P3SnapshotStore(path: url.path)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let quest = makeQuests(now: now)
        let battle = makeBattle(revision: 7, status: .active)
        let log = makeLog(sessionID: battle.sessionID, startedAt: now)

        try store.save(
            quests: quest,
            questRevision: 4,
            currentBattle: battle,
            battleRevision: 7,
            battleLogs: [log],
            updatedAt: now
        )
        let restored = try store.restore(now: now)

        XCTAssertEqual(restored.questRevision, 4)
        XCTAssertEqual(restored.battleRevision, 7)
        XCTAssertEqual(restored.quests.tracking, quest.tracking)
        XCTAssertEqual(restored.quests.completed, quest.completed)
        XCTAssertEqual(restored.currentBattle?.snapshot, battle)
        XCTAssertEqual(restored.currentBattle?.status, .restoredIncomplete)
        XCTAssertEqual(restored.battleLogs, [log])
        XCTAssertTrue(restored.recoveryIssues.isEmpty)
        XCTAssertEqual(try queryText(path: url.path, sql: "PRAGMA journal_mode"), "wal")
        XCTAssertEqual(try queryInt(path: url.path, sql: "SELECT value FROM p3_meta WHERE key='schema'"), 1)
        XCTAssertEqual(try queryText(path: url.path, sql: "SELECT status FROM battle_current WHERE id=1"), "restoredIncomplete")
    }

    func testInjectedFailureRollsBackQuestBattleLogsAndRevisions() throws {
        let url = databaseURL()
        try P3SnapshotStore(path: url.path).save(
            quests: makeQuests(now: Date(timeIntervalSince1970: 100)),
            questRevision: 1,
            currentBattle: makeBattle(revision: 1, status: .completed),
            battleRevision: 1,
            battleLogs: [],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let failing = try P3SnapshotStore(path: url.path) {
            $0 == .afterCurrentBattle
        }
        XCTAssertThrowsError(try failing.save(
            quests: .init(),
            questRevision: 2,
            currentBattle: nil,
            battleRevision: 2,
            battleLogs: [makeLog(sessionID: UUID(), startedAt: Date())]
        )) {
            XCTAssertEqual($0 as? P3SnapshotStore.StoreError, .injectedFailure(.afterCurrentBattle))
        }
        let restored = try failing.restore()
        XCTAssertEqual(restored.questRevision, 1)
        XCTAssertEqual(restored.battleRevision, 1)
        XCTAssertFalse(restored.quests.tracking.isEmpty)
        XCTAssertNotNil(restored.currentBattle)
        XCTAssertTrue(restored.battleLogs.isEmpty)
    }

    func testEitherRevisionRegressionRejectsWholeSave() throws {
        let store = try P3SnapshotStore(path: databaseURL().path)
        try store.save(
            quests: .init(), questRevision: 10,
            currentBattle: nil, battleRevision: 20, battleLogs: []
        )
        XCTAssertThrowsError(try store.save(
            quests: makeQuests(now: Date()), questRevision: 9,
            currentBattle: makeBattle(revision: 21), battleRevision: 21, battleLogs: []
        )) {
            XCTAssertEqual(
                $0 as? P3SnapshotStore.StoreError,
                .revisionRegression(domain: .quest, current: 10, attempted: 9)
            )
        }
        XCTAssertThrowsError(try store.save(
            quests: makeQuests(now: Date()), questRevision: 11,
            currentBattle: nil, battleRevision: 19, battleLogs: []
        )) {
            XCTAssertEqual(
                $0 as? P3SnapshotStore.StoreError,
                .revisionRegression(domain: .battle, current: 20, attempted: 19)
            )
        }
        let restored = try store.restore()
        XCTAssertEqual(restored.questRevision, 10)
        XCTAssertEqual(restored.battleRevision, 20)
        XCTAssertTrue(restored.quests.tracking.isEmpty)
    }

    func testConcurrentSavesFinishAtMaximumRevisionsWithoutBusyLeak() throws {
        let store = try P3SnapshotStore(path: databaseURL().path)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "p3.snapshot.concurrent", attributes: .concurrent)
        let errors = P3LockedErrors()
        for revision in 1...20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try store.save(
                        quests: .init(),
                        questRevision: Int64(revision),
                        currentBattle: nil,
                        battleRevision: Int64(revision),
                        battleLogs: []
                    )
                } catch let error as P3SnapshotStore.StoreError {
                    if case .revisionRegression = error { return }
                    errors.append(error)
                } catch {
                    errors.append(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        let restored = try store.restore()
        XCTAssertEqual(restored.questRevision, 20)
        XCTAssertEqual(restored.battleRevision, 20)
    }

    func testCorruptRowsAreReportedAndOtherRowsStillRestore() throws {
        let url = databaseURL()
        let store = try P3SnapshotStore(path: url.path)
        let now = Date(timeIntervalSince1970: 10_000)
        let quests = QuestListSnapshot(
            tracking: [
                1: .init(questID: 1, isActive: true, counters: [1], startedAt: now, precision: .exact),
                2: .init(questID: 2, isActive: true, counters: [2], startedAt: now, precision: .exact)
            ]
        )
        let goodLog = makeLog(sessionID: UUID(), startedAt: now)
        let badLog = makeLog(sessionID: UUID(), startedAt: now.addingTimeInterval(-1))
        try store.save(
            quests: quests, questRevision: 1,
            currentBattle: makeBattle(revision: 1), battleRevision: 1,
            battleLogs: [goodLog, badLog], updatedAt: now
        )
        try execute(
            path: url.path,
            sql: """
            UPDATE quest_progress SET payload=x'FFFF' WHERE quest_id=1;
            UPDATE battle_current SET payload=x'FFFF' WHERE id=1;
            UPDATE battle_log SET payload=x'FFFF' WHERE session_id='\(badLog.sessionID.uuidString)';
            """
        )

        let restored = try store.restore(now: now)
        XCTAssertNil(restored.quests.tracking[1])
        XCTAssertEqual(restored.quests.tracking[2]?.counters, [2])
        XCTAssertNil(restored.currentBattle)
        XCTAssertEqual(restored.battleLogs, [goodLog])
        XCTAssertEqual(restored.recoveryIssues.count, 3)
        XCTAssertEqual(Set(restored.recoveryIssues.map(\.table)), ["quest_progress", "battle_current", "battle_log"])
    }

    func testTooNewSchemaIsRejected() throws {
        let url = databaseURL()
        try execute(
            path: url.path,
            sql: "CREATE TABLE p3_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO p3_meta VALUES('schema','99')"
        )
        XCTAssertThrowsError(try P3SnapshotStore(path: url.path)) {
            XCTAssertEqual(
                $0 as? P3SnapshotStore.StoreError,
                .schemaTooNew(found: 99, supported: 1)
            )
        }
    }

    func testBattleLogCapacityKeepsNewestOneHundred() throws {
        let store = try P3SnapshotStore(path: databaseURL().path)
        let logs = (0..<105).map {
            makeLog(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        try store.save(
            quests: .init(), questRevision: 1,
            currentBattle: nil, battleRevision: 1, battleLogs: logs
        )
        let restored = try store.restore()
        XCTAssertEqual(restored.battleLogs.count, 100)
        XCTAssertEqual(restored.battleLogs.first?.startedAt, Date(timeIntervalSince1970: 104))
        XCTAssertEqual(restored.battleLogs.last?.startedAt, Date(timeIntervalSince1970: 5))
    }

    func testCompletedQuestExpiresAfterSevenDaysButActiveStateNeverDoes() throws {
        let url = databaseURL()
        let store = try P3SnapshotStore(path: url.path)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-P3SnapshotStore.completedQuestRetention - 1)
        let recent = now.addingTimeInterval(-60)
        let quests = QuestListSnapshot(
            tracking: [
                1: .init(questID: 1, isActive: true, counters: [4], startedAt: old, precision: .exact)
            ],
            completed: [
                .init(questID: 1, completedAt: old),
                .init(questID: 2, completedAt: old),
                .init(questID: 3, completedAt: recent)
            ]
        )
        try store.save(
            quests: quests, questRevision: 1,
            currentBattle: nil, battleRevision: 1, battleLogs: [], updatedAt: now
        )
        let restored = try store.restore(now: now)
        XCTAssertEqual(restored.quests.tracking[1]?.counters, [4])
        XCTAssertEqual(restored.quests.completed, [.init(questID: 3, completedAt: recent)])
        XCTAssertEqual(try queryInt(path: url.path, sql: "SELECT COUNT(*) FROM quest_progress"), 2)
    }

    private func makeQuests(now: Date) -> QuestListSnapshot {
        .init(
            tracking: [
                101: .init(
                    questID: 101,
                    isActive: true,
                    counters: [3, 1],
                    startedAt: now,
                    precision: .exact
                )
            ],
            completed: [.init(questID: 202, completedAt: now)],
            updatedAt: now
        )
    }

    private func makeBattle(
        revision: Int64,
        status: BattleSessionStatus = .active
    ) -> BattleSnapshot {
        BattleSnapshot(
            sessionID: UUID(),
            endpoint: BattleEndpoint("/api_req_sortie/battle"),
            kind: .sortie,
            map: .init(mapAreaID: 1, mapNumber: 2, nodeID: 3),
            formation: nil,
            friendlyMain: .init(),
            friendlyEscort: nil,
            enemyMain: .init(),
            enemyEscort: nil,
            phases: [],
            status: status,
            warnings: [],
            revision: revision
        )
    }

    private func makeLog(sessionID: UUID, startedAt: Date) -> BattleLogEntry {
        BattleLogEntry(
            sessionID: sessionID,
            startedAt: startedAt,
            map: nil,
            kind: .sortie,
            enemyFleetName: nil,
            predictedRank: nil,
            actualRank: nil,
            friendlyFinalHP: [],
            enemyFinalHP: [],
            escapedPositions: [],
            dameconSummary: nil,
            phases: []
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SnapshotTests-\(UUID())", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func databaseURL() -> URL {
        temporaryDirectory().appendingPathComponent("p3.sqlite")
    }

    private func execute(path: String, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func queryInt(path: String, sql: String) throws -> Int {
        Int(try queryText(path: path, sql: sql))!
    }

    private func queryText(path: String, sql: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw CocoaError(.fileReadUnknown)
        }
        return String(cString: value)
    }
}

private final class P3LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []
    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}
