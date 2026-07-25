import Foundation
import SQLite3

public struct RestoredGameSnapshot<State: Sendable>: Sendable {
    public let revision: Int64
    public let updatedAt: Date
    public let state: State
    public let isRestored: Bool
    public let isStale: Bool

    public init(revision: Int64, updatedAt: Date, state: State, isRestored: Bool, isStale: Bool) {
        self.revision = revision
        self.updatedAt = updatedAt
        self.state = state
        self.isRestored = isRestored
        self.isStale = isStale
    }
}

/// SQLite-backed, single-row game state store shared by the app and (later) WidgetKit.
///
/// The current state and its projected timers are replaced in one `BEGIN IMMEDIATE`
/// transaction. Callers inject the database path so GameCore remains independent from
/// App Group entitlements and application container policy.
public final class GameSnapshotStore: @unchecked Sendable {
    public static let schemaVersion = 1

    public enum SavePhase: Equatable, Sendable {
        case afterCurrentSnapshot
        case afterTimerReplacement
    }

    public enum StoreError: Error, Equatable, Sendable {
        case open(code: Int32, message: String)
        case schemaTooNew(found: Int, supported: Int)
        case corruptDatabase(message: String)
        case corruptPayload(message: String)
        case revisionRegression(current: Int64, attempted: Int64)
        case readOnly(message: String)
        case busy(message: String)
        case sqlite(operation: String, code: Int32, message: String)
        case injectedFailure(SavePhase)
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let lock = NSLock()
    private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let failureInjector: (@Sendable (SavePhase) -> Bool)?

    public init(
        path: String,
        busyTimeoutMilliseconds: Int32 = 5_000,
        failureInjector: (@Sendable (SavePhase) -> Bool)? = nil
    ) throws {
        self.failureInjector = failureInjector
        encoder = JSONEncoder()
        decoder = JSONDecoder()

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

    /// Saves state and timers atomically. Equal revisions may refresh an existing
    /// snapshot, while an older revision is rejected.
    public func save<State: Encodable>(
        state: State,
        revision: Int64,
        updatedAt: Date = Date(),
        timers: [GameTimer] = []
    ) throws {
        let payload: Data
        do {
            payload = try encoder.encode(state)
        } catch {
            throw StoreError.corruptPayload(message: "Unable to encode snapshot: \(error)")
        }

        try synchronized {
            try execute("BEGIN IMMEDIATE")
            var committed = false
            defer {
                if !committed { try? execute("ROLLBACK") }
            }

            if let current = try currentRevision(), revision < current {
                throw StoreError.revisionRegression(current: current, attempted: revision)
            }

            let snapshot = try prepare(
                """
                INSERT INTO current_snapshot (id, revision, updated_at, state_json)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    revision=excluded.revision,
                    updated_at=excluded.updated_at,
                    state_json=excluded.state_json
                """
            )
            defer { sqlite3_finalize(snapshot) }
            try bind(revision, to: snapshot, at: 1)
            try bind(updatedAt.timeIntervalSince1970, to: snapshot, at: 2)
            try bind(payload, to: snapshot, at: 3)
            try stepDone(snapshot, operation: "replace current snapshot")

            if failureInjector?(.afterCurrentSnapshot) == true {
                throw StoreError.injectedFailure(.afterCurrentSnapshot)
            }

            try execute("DELETE FROM timer_snapshot")
            for timer in timers where !timer.isCancelled {
                try insert(timer)
            }

            if failureInjector?(.afterTimerReplacement) == true {
                throw StoreError.injectedFailure(.afterTimerReplacement)
            }

            try execute("COMMIT")
            committed = true
        }
    }

    public func restore<State: Decodable & Sendable>(
        _ type: State.Type = State.self,
        staleAfter: TimeInterval,
        now: Date = Date()
    ) throws -> RestoredGameSnapshot<State>? {
        try synchronized {
            let statement = try prepare(
                "SELECT revision, updated_at, state_json FROM current_snapshot WHERE id = 1"
            )
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw mappedError(operation: "read current snapshot", code: result)
            }

            let revision = sqlite3_column_int64(statement, 0)
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            guard let bytes = sqlite3_column_blob(statement, 2) else {
                throw StoreError.corruptPayload(message: "current_snapshot.state_json is NULL")
            }
            let count = Int(sqlite3_column_bytes(statement, 2))
            let payload = Data(bytes: bytes, count: count)
            let state: State
            do {
                state = try decoder.decode(type, from: payload)
            } catch {
                throw StoreError.corruptPayload(message: "Unable to decode snapshot: \(error)")
            }
            return RestoredGameSnapshot(
                revision: revision,
                updatedAt: updatedAt,
                state: state,
                isRestored: true,
                isStale: now.timeIntervalSince(updatedAt) > max(0, staleAfter)
            )
        }
    }

    /// Returns timers ordered by completion time. By default timers more than one
    /// day overdue are treated as clearly expired, while recently completed timers
    /// remain available to notification/UI reconciliation.
    public func timers(
        now: Date = Date(),
        clearlyExpiredAfter: TimeInterval = 24 * 60 * 60
    ) throws -> [GameTimer] {
        try synchronized {
            let cutoff = now.addingTimeInterval(-max(0, clearlyExpiredAfter)).timeIntervalSince1970
            let statement = try prepare(
                """
                SELECT timer_id, kind, slot, title, detail, completion_at, source_revision
                FROM timer_snapshot
                WHERE completion_at >= ?
                ORDER BY completion_at ASC, timer_id ASC
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(cutoff, to: statement, at: 1)

            var values: [GameTimer] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return values }
                guard result == SQLITE_ROW else {
                    throw mappedError(operation: "read timers", code: result)
                }
                guard let id = text(statement, 0),
                      let rawKind = text(statement, 1),
                      let kind = GameTimer.Kind(rawValue: rawKind),
                      let title = text(statement, 3),
                      let detail = text(statement, 4) else {
                    throw StoreError.corruptPayload(message: "timer_snapshot contains invalid values")
                }
                let slot = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 2))
                values.append(GameTimer(
                    id: id,
                    kind: kind,
                    slot: slot,
                    title: title,
                    detail: detail,
                    completionDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    sourceRevision: sqlite3_column_int64(statement, 6)
                ))
            }
        }
    }

    /// Removes only old timer rows; the current game snapshot is intentionally kept.
    @discardableResult
    public func removeExpiredTimers(before cutoff: Date) throws -> Int {
        try synchronized {
            let statement = try prepare("DELETE FROM timer_snapshot WHERE completion_at < ?")
            defer { sqlite3_finalize(statement) }
            try bind(cutoff.timeIntervalSince1970, to: statement, at: 1)
            try stepDone(statement, operation: "delete expired timers")
            return Int(sqlite3_changes(database))
        }
    }

    private func migrateSchema() throws {
        try synchronized {
            let tableExists = try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'"
            ) > 0
            if tableExists {
                let version = try scalarInt("SELECT version FROM schema_meta LIMIT 1")
                if version > Self.schemaVersion {
                    throw StoreError.schemaTooNew(found: version, supported: Self.schemaVersion)
                }
                if version == Self.schemaVersion { return }
            }

            try execute("BEGIN IMMEDIATE")
            var committed = false
            defer { if !committed { try? execute("ROLLBACK") } }
            try execute("CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER NOT NULL)")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS current_snapshot (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    revision INTEGER NOT NULL,
                    updated_at REAL NOT NULL,
                    state_json BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS timer_snapshot (
                    timer_id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    slot INTEGER,
                    title TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    completion_at REAL NOT NULL,
                    source_revision INTEGER NOT NULL
                )
                """
            )
            try execute("CREATE INDEX IF NOT EXISTS timer_completion_idx ON timer_snapshot(completion_at)")
            try execute("DELETE FROM schema_meta")
            try execute("INSERT INTO schema_meta(version) VALUES (1)")
            try execute("COMMIT")
            committed = true
        }
    }

    private func insert(_ timer: GameTimer) throws {
        let statement = try prepare(
            """
            INSERT INTO timer_snapshot
                (timer_id, kind, slot, title, detail, completion_at, source_revision)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(timer.id, to: statement, at: 1)
        try bind(timer.kind.rawValue, to: statement, at: 2)
        if let slot = timer.slot { try bind(Int64(slot), to: statement, at: 3) }
        else { try check(sqlite3_bind_null(statement, 3), operation: "bind timer slot") }
        try bind(timer.title, to: statement, at: 4)
        try bind(timer.detail, to: statement, at: 5)
        try bind(timer.completionDate.timeIntervalSince1970, to: statement, at: 6)
        try bind(timer.sourceRevision, to: statement, at: 7)
        try stepDone(statement, operation: "insert timer")
    }

    private func currentRevision() throws -> Int64? {
        let statement = try prepare("SELECT revision FROM current_snapshot WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw mappedError(operation: "read revision", code: result) }
        return sqlite3_column_int64(statement, 0)
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
        guard result == SQLITE_ROW else { throw mappedError(operation: "read schema", code: result) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transientDestructor)
        }
        try check(result, operation: "bind text")
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transientDestructor)
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
