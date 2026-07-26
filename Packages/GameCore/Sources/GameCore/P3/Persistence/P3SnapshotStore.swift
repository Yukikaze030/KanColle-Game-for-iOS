import Foundation
import SQLite3

public enum P3CurrentBattleStatus: String, Codable, Sendable, Equatable {
    case active
    case awaitingResult
    case completed
    case restoredIncomplete
}

public struct RestoredP3CurrentBattle: Sendable, Equatable {
    public let snapshot: BattleSnapshot
    public let status: P3CurrentBattleStatus
    public let updatedAt: Date
}

public struct P3RecoveryIssue: Sendable, Equatable {
    public let table: String
    public let key: String
    public let message: String
}

public struct RestoredP3Snapshot: Sendable, Equatable {
    public let questRevision: Int64
    public let battleRevision: Int64
    public let quests: QuestListSnapshot
    public let currentBattle: RestoredP3CurrentBattle?
    public let battleLogs: [BattleLogEntry]
    public let recoveryIssues: [P3RecoveryIssue]
}

/// SQLite persistence for P3 quest progress and battle history.
///
/// The database URL is injected by the application so this target does not depend
/// on App Group entitlements or alter the P2/WidgetKit schema.
public final class P3SnapshotStore: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let maximumBattleLogs = 100
    public static let completedQuestRetention: TimeInterval = 7 * 24 * 60 * 60

    public enum RevisionDomain: String, Sendable, Equatable {
        case battle
        case quest
    }

    public enum SavePhase: Sendable, Equatable {
        case afterQuestReplacement
        case afterCurrentBattle
        case afterBattleLogReplacement
    }

    public enum StoreError: Error, Sendable, Equatable {
        case open(code: Int32, message: String)
        case schemaTooNew(found: Int, supported: Int)
        case corruptDatabase(message: String)
        case corruptPayload(message: String)
        case revisionRegression(domain: RevisionDomain, current: Int64, attempted: Int64)
        case readOnly(message: String)
        case busy(message: String)
        case sqlite(operation: String, code: Int32, message: String)
        case injectedFailure(SavePhase)
    }

    private struct QuestPayload: Codable {
        let tracking: QuestTrackingState?
        let completed: [CompletedQuest]
    }

    private struct EncodedQuestRow {
        let questID: Int
        let payload: Data
        let updatedAt: Date
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let lock = NSLock()
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let failureInjector: (@Sendable (SavePhase) -> Bool)?

    public init(
        path: String,
        busyTimeoutMilliseconds: Int32 = 5_000,
        failureInjector: (@Sendable (SavePhase) -> Bool)? = nil
    ) throws {
        self.failureInjector = failureInjector

        let fileManager = FileManager.default
        let parentPath = (path as NSString).deletingLastPathComponent
        if fileManager.fileExists(atPath: path), !fileManager.isWritableFile(atPath: path) {
            throw StoreError.readOnly(message: "Database file is not writable: \(path)")
        }
        if !fileManager.fileExists(atPath: path),
           fileManager.fileExists(atPath: parentPath),
           !fileManager.isWritableFile(atPath: parentPath) {
            throw StoreError.readOnly(message: "Database directory is not writable: \(parentPath)")
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = Self.errorMessage(opened)
            if let opened { sqlite3_close_v2(opened) }
            throw StoreError.open(code: result, message: message)
        }
        database = opened

        do {
            try check(sqlite3_busy_timeout(opened, busyTimeoutMilliseconds), operation: "busy_timeout")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try migrateSchema()
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        lock.lock()
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        lock.unlock()
    }

    /// Replaces the P3 snapshot in one transaction. Equal revisions may refresh
    /// payloads; either domain moving backwards rejects the whole transaction.
    public func save(
        quests: QuestListSnapshot,
        questRevision: Int64,
        currentBattle: BattleSnapshot?,
        battleRevision: Int64,
        battleLogs: [BattleLogEntry],
        updatedAt: Date = Date()
    ) throws {
        let questRows = try encodedQuestRows(from: quests, now: updatedAt)
        let battlePayload = try encode(currentBattle, context: "current battle")
        let logRows = try normalizedLogs(battleLogs).map {
            ($0, try encode($0, context: "battle log \($0.sessionID.uuidString)"))
        }

        try synchronized {
            try execute("BEGIN IMMEDIATE")
            var committed = false
            defer { if !committed { try? execute("ROLLBACK") } }

            try rejectRegression(.quest, attempted: questRevision)
            try rejectRegression(.battle, attempted: battleRevision)

            try execute("DELETE FROM quest_progress")
            for row in questRows { try insert(row) }
            if failureInjector?(.afterQuestReplacement) == true {
                throw StoreError.injectedFailure(.afterQuestReplacement)
            }

            try execute("DELETE FROM battle_current")
            if let currentBattle, let battlePayload {
                try insertCurrentBattle(currentBattle, payload: battlePayload, updatedAt: updatedAt)
            }
            if failureInjector?(.afterCurrentBattle) == true {
                throw StoreError.injectedFailure(.afterCurrentBattle)
            }

            try execute("DELETE FROM battle_log")
            for (entry, payload) in logRows { try insertLog(entry, payload: payload) }
            if failureInjector?(.afterBattleLogReplacement) == true {
                throw StoreError.injectedFailure(.afterBattleLogReplacement)
            }

            try setMeta("quest_revision", value: String(questRevision))
            try setMeta("battle_revision", value: String(battleRevision))
            try execute("COMMIT")
            committed = true
        }
    }

    /// Restores every independently decodable row. A malformed quest, current
    /// battle, or log is reported and skipped without making the database unusable.
    ///
    /// An interrupted active/awaiting-result battle is marked `restoredIncomplete`
    /// both in the returned model and in SQLite. A later save replaces that row
    /// when the next battle begins.
    public func restore(now: Date = Date()) throws -> RestoredP3Snapshot {
        try synchronized {
            var issues: [P3RecoveryIssue] = []
            let questRevision = try metaInt64("quest_revision") ?? 0
            let battleRevision = try metaInt64("battle_revision") ?? 0
            let questResult = try readQuests(now: now, issues: &issues)
            let battleResult = try readCurrentBattle(issues: &issues)
            let logs = try readBattleLogs(issues: &issues)

            if !questResult.maintenance.isEmpty || battleResult.shouldMarkIncomplete {
                try execute("BEGIN IMMEDIATE")
                var committed = false
                defer { if !committed { try? execute("ROLLBACK") } }
                for row in questResult.maintenance {
                    if let row { try update(row) }
                    else { /* deletion is performed by readQuests using its key list */ }
                }
                for questID in questResult.deleteIDs { try deleteQuest(questID) }
                if battleResult.shouldMarkIncomplete {
                    try updateCurrentBattleStatus(.restoredIncomplete)
                }
                try execute("COMMIT")
                committed = true
            }

            return RestoredP3Snapshot(
                questRevision: questRevision,
                battleRevision: battleRevision,
                quests: questResult.snapshot,
                currentBattle: battleResult.value,
                battleLogs: logs,
                recoveryIssues: issues
            )
        }
    }

    private func migrateSchema() throws {
        try synchronized {
            let hasMeta = try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='p3_meta'"
            ) > 0
            if hasMeta, let version = try metaInt64("schema") {
                if version > Int64(Self.schemaVersion) {
                    throw StoreError.schemaTooNew(found: Int(version), supported: Self.schemaVersion)
                }
                if version == Int64(Self.schemaVersion) { return }
            }

            try execute("BEGIN IMMEDIATE")
            var committed = false
            defer { if !committed { try? execute("ROLLBACK") } }
            try execute("CREATE TABLE IF NOT EXISTS p3_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS quest_progress (
                    quest_id INTEGER PRIMARY KEY,
                    payload BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS battle_log (
                    session_id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS battle_current (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    payload BLOB NOT NULL,
                    status TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            try execute("CREATE INDEX IF NOT EXISTS battle_log_started_idx ON battle_log(started_at DESC)")
            try setMeta("schema", value: String(Self.schemaVersion))
            if try metaInt64("quest_revision") == nil { try setMeta("quest_revision", value: "0") }
            if try metaInt64("battle_revision") == nil { try setMeta("battle_revision", value: "0") }
            try execute("COMMIT")
            committed = true
        }
    }

    private func encodedQuestRows(from snapshot: QuestListSnapshot, now: Date) throws -> [EncodedQuestRow] {
        let cutoff = now.addingTimeInterval(-Self.completedQuestRetention)
        let completed = Dictionary(grouping: snapshot.completed.filter { $0.completedAt >= cutoff }, by: \.questID)
        let ids = Set(snapshot.tracking.keys).union(completed.keys)
        return try ids.sorted().map { questID in
            let tracking = snapshot.tracking[questID]
            let completions = (completed[questID] ?? []).sorted { $0.completedAt < $1.completedAt }
            let payload = try encode(
                QuestPayload(tracking: tracking, completed: completions),
                context: "quest \(questID)"
            )
            let dates = completions.map(\.completedAt) + [tracking?.startedAt].compactMap { $0 }
            return EncodedQuestRow(
                questID: questID,
                payload: payload,
                updatedAt: dates.max() ?? now
            )
        }
    }

    private func normalizedLogs(_ logs: [BattleLogEntry]) -> [BattleLogEntry] {
        var byID: [UUID: BattleLogEntry] = [:]
        for log in logs { byID[log.sessionID] = log }
        return byID.values.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.sessionID.uuidString < $1.sessionID.uuidString
            }
            return $0.startedAt > $1.startedAt
        }
        .prefix(Self.maximumBattleLogs)
        .map { $0 }
    }

    private func insert(_ row: EncodedQuestRow) throws {
        let statement = try prepare(
            "INSERT INTO quest_progress(quest_id, payload, updated_at) VALUES (?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(Int64(row.questID), to: statement, at: 1)
        try bind(row.payload, to: statement, at: 2)
        try bind(row.updatedAt.timeIntervalSince1970, to: statement, at: 3)
        try stepDone(statement, operation: "insert quest progress")
    }

    private func update(_ row: EncodedQuestRow) throws {
        let statement = try prepare(
            "UPDATE quest_progress SET payload = ?, updated_at = ? WHERE quest_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(row.payload, to: statement, at: 1)
        try bind(row.updatedAt.timeIntervalSince1970, to: statement, at: 2)
        try bind(Int64(row.questID), to: statement, at: 3)
        try stepDone(statement, operation: "clean completed quest progress")
    }

    private func deleteQuest(_ questID: Int) throws {
        let statement = try prepare("DELETE FROM quest_progress WHERE quest_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(Int64(questID), to: statement, at: 1)
        try stepDone(statement, operation: "delete expired completed quest")
    }

    private func insertCurrentBattle(_ battle: BattleSnapshot, payload: Data, updatedAt: Date) throws {
        let statement = try prepare(
            "INSERT INTO battle_current(id, payload, status, updated_at) VALUES (1, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(payload, to: statement, at: 1)
        try bind(status(for: battle.status).rawValue, to: statement, at: 2)
        try bind(updatedAt.timeIntervalSince1970, to: statement, at: 3)
        try stepDone(statement, operation: "insert current battle")
    }

    private func insertLog(_ entry: BattleLogEntry, payload: Data) throws {
        let statement = try prepare(
            "INSERT INTO battle_log(session_id, started_at, payload) VALUES (?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(entry.sessionID.uuidString, to: statement, at: 1)
        try bind(entry.startedAt.timeIntervalSince1970, to: statement, at: 2)
        try bind(payload, to: statement, at: 3)
        try stepDone(statement, operation: "insert battle log")
    }

    private func readQuests(
        now: Date,
        issues: inout [P3RecoveryIssue]
    ) throws -> (snapshot: QuestListSnapshot, maintenance: [EncodedQuestRow?], deleteIDs: [Int]) {
        let statement = try prepare(
            "SELECT quest_id, payload, updated_at FROM quest_progress ORDER BY quest_id"
        )
        defer { sqlite3_finalize(statement) }
        let cutoff = now.addingTimeInterval(-Self.completedQuestRetention)
        var tracking: [Int: QuestTrackingState] = [:]
        var completed: [CompletedQuest] = []
        var maintenance: [EncodedQuestRow?] = []
        var deleteIDs: [Int] = []
        var newest: Date?

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw mappedError(operation: "read quest progress", code: result)
            }
            let questID = Int(sqlite3_column_int64(statement, 0))
            guard let payload = data(statement, 1) else {
                issues.append(.init(table: "quest_progress", key: String(questID), message: "payload is NULL"))
                continue
            }
            do {
                let value = try decoder.decode(QuestPayload.self, from: payload)
                if let valueTracking = value.tracking { tracking[questID] = valueTracking }
                let retained = value.completed.filter { $0.completedAt >= cutoff }
                completed.append(contentsOf: retained)
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                newest = max(newest ?? updatedAt, updatedAt)
                if retained.count != value.completed.count {
                    if value.tracking == nil, retained.isEmpty {
                        maintenance.append(nil)
                        deleteIDs.append(questID)
                    } else {
                        let encoded = try encoder.encode(QuestPayload(
                            tracking: value.tracking,
                            completed: retained
                        ))
                        let dates = retained.map(\.completedAt) + [value.tracking?.startedAt].compactMap { $0 }
                        maintenance.append(.init(
                            questID: questID,
                            payload: encoded,
                            updatedAt: dates.max() ?? now
                        ))
                    }
                }
            } catch {
                issues.append(.init(
                    table: "quest_progress",
                    key: String(questID),
                    message: "Unable to decode payload: \(error)"
                ))
            }
        }

        return (
            QuestListSnapshot(
                items: [:],
                tracking: tracking,
                completed: completed.sorted { $0.completedAt < $1.completedAt },
                updatedAt: newest
            ),
            maintenance,
            deleteIDs
        )
    }

    private func readCurrentBattle(
        issues: inout [P3RecoveryIssue]
    ) throws -> (value: RestoredP3CurrentBattle?, shouldMarkIncomplete: Bool) {
        let statement = try prepare(
            "SELECT payload, status, updated_at FROM battle_current WHERE id = 1"
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return (nil, false) }
        guard result == SQLITE_ROW else {
            throw mappedError(operation: "read current battle", code: result)
        }
        guard let payload = data(statement, 0), let rawStatus = text(statement, 1) else {
            issues.append(.init(table: "battle_current", key: "1", message: "invalid columns"))
            return (nil, false)
        }
        guard let storedStatus = P3CurrentBattleStatus(rawValue: rawStatus) else {
            issues.append(.init(table: "battle_current", key: "1", message: "unknown status \(rawStatus)"))
            return (nil, false)
        }
        do {
            let snapshot = try decoder.decode(BattleSnapshot.self, from: payload)
            let interrupted = storedStatus == .active || storedStatus == .awaitingResult
            let restoredStatus: P3CurrentBattleStatus = interrupted ? .restoredIncomplete : storedStatus
            return (
                .init(
                    snapshot: snapshot,
                    status: restoredStatus,
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                ),
                interrupted
            )
        } catch {
            issues.append(.init(
                table: "battle_current",
                key: "1",
                message: "Unable to decode payload: \(error)"
            ))
            return (nil, false)
        }
    }

    private func readBattleLogs(issues: inout [P3RecoveryIssue]) throws -> [BattleLogEntry] {
        let statement = try prepare(
            "SELECT session_id, payload FROM battle_log ORDER BY started_at DESC LIMIT 100"
        )
        defer { sqlite3_finalize(statement) }
        var logs: [BattleLogEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return logs }
            guard result == SQLITE_ROW else {
                throw mappedError(operation: "read battle logs", code: result)
            }
            let key = text(statement, 0) ?? "<NULL>"
            guard let payload = data(statement, 1) else {
                issues.append(.init(table: "battle_log", key: key, message: "payload is NULL"))
                continue
            }
            do {
                logs.append(try decoder.decode(BattleLogEntry.self, from: payload))
            } catch {
                issues.append(.init(
                    table: "battle_log",
                    key: key,
                    message: "Unable to decode payload: \(error)"
                ))
            }
        }
    }

    private func status(for status: BattleSessionStatus) -> P3CurrentBattleStatus {
        switch status {
        case .active: .active
        case .awaitingResult: .awaitingResult
        case .completed: .completed
        }
    }

    private func updateCurrentBattleStatus(_ status: P3CurrentBattleStatus) throws {
        let statement = try prepare("UPDATE battle_current SET status = ? WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        try bind(status.rawValue, to: statement, at: 1)
        try stepDone(statement, operation: "mark restored battle incomplete")
    }

    private func rejectRegression(_ domain: RevisionDomain, attempted: Int64) throws {
        let current = try metaInt64("\(domain.rawValue)_revision") ?? 0
        if attempted < current {
            throw StoreError.revisionRegression(domain: domain, current: current, attempted: attempted)
        }
    }

    private func setMeta(_ key: String, value: String) throws {
        let statement = try prepare(
            """
            INSERT INTO p3_meta(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        try bind(value, to: statement, at: 2)
        try stepDone(statement, operation: "write meta \(key)")
    }

    private func metaInt64(_ key: String) throws -> Int64? {
        let statement = try prepare("SELECT value FROM p3_meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw mappedError(operation: "read meta \(key)", code: result) }
        guard let value = text(statement, 0), let integer = Int64(value) else {
            throw StoreError.corruptDatabase(message: "p3_meta.\(key) is not an integer")
        }
        return integer
    }

    private func encode<Value: Encodable>(_ value: Value?, context: String) throws -> Data? {
        guard let value else { return nil }
        do { return try encoder.encode(value) }
        catch { throw StoreError.corruptPayload(message: "Unable to encode \(context): \(error)") }
    }

    private func encode<Value: Encodable>(_ value: Value, context: String) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw StoreError.corruptPayload(message: "Unable to encode \(context): \(error)") }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        defer { sqlite3_free(errorPointer) }
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? Self.errorMessage(database)
            throw mappedError(operation: "execute SQL", code: result, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw mappedError(operation: "prepare SQL", code: result)
        }
        return statement
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw mappedError(operation: "read scalar", code: result) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transientDestructor)
        }
        try check(result, operation: "bind text")
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transientDestructor)
        }
        try check(result, operation: "bind blob")
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
        try check(sqlite3_bind_int64(statement, index, value), operation: "bind integer")
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        try check(sqlite3_bind_double(statement, index, value), operation: "bind double")
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw mappedError(operation: operation, code: result) }
    }

    private func check(_ code: Int32, operation: String) throws {
        guard code == SQLITE_OK else { throw mappedError(operation: operation, code: code) }
    }

    private func mappedError(operation: String, code: Int32, message: String? = nil) -> StoreError {
        let detail = message ?? Self.errorMessage(database)
        switch code {
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corruptDatabase(message: detail)
        case SQLITE_READONLY, SQLITE_PERM:
            return .readOnly(message: detail)
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .busy(message: detail)
        default:
            return .sqlite(operation: operation, code: code, message: detail)
        }
    }

    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func errorMessage(_ database: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(database) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}
