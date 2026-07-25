import Foundation
import SQLite3

public struct VersionRow: Equatable, Sendable {
    public let key: String
    public let version: String?
    public let lastModified: String?
    public let maxAgeSeconds: Int?
    public let fetchedAt: Date

    public init(
        key: String,
        version: String?,
        lastModified: String?,
        maxAgeSeconds: Int?,
        fetchedAt: Date
    ) {
        self.key = key
        self.version = version
        self.lastModified = lastModified
        self.maxAgeSeconds = maxAgeSeconds
        self.fetchedAt = fetchedAt
    }
}

public final class VersionStore: @unchecked Sendable {
    public enum StoreError: Error, Equatable, Sendable {
        case open(code: Int32, message: String)
        case execute(code: Int32, message: String)
        case prepare(code: Int32, message: String)
        case bind(code: Int32, message: String)
        case step(code: Int32, message: String)
    }

    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private let lock = NSLock()
    private var database: OpaquePointer?

    public init(path: String) throws {
        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &openedDatabase, flags, nil)
        guard result == SQLITE_OK, let openedDatabase else {
            let message = Self.errorMessage(from: openedDatabase)
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw StoreError.open(code: result, message: message)
        }

        database = openedDatabase
        do {
            try executeUnlocked(
                """
                CREATE TABLE IF NOT EXISTS version_table (
                    KEY TEXT PRIMARY KEY NOT NULL,
                    VERSION TEXT,
                    LAST_MODIFIED TEXT,
                    MAX_AGE INTEGER,
                    FETCHED_AT REAL NOT NULL
                )
                """
            )
        } catch {
            sqlite3_close_v2(openedDatabase)
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

    public func put(
        key: String,
        version: String?,
        lastModified: String?,
        maxAgeSeconds: Int?
    ) throws {
        try withLock {
            let statement = try prepareUnlocked(
                """
                INSERT OR REPLACE INTO version_table
                    (KEY, VERSION, LAST_MODIFIED, MAX_AGE, FETCHED_AT)
                VALUES (?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }

            try bindText(key, to: statement, at: 1)
            try bindOptionalText(version, to: statement, at: 2)
            try bindOptionalText(lastModified, to: statement, at: 3)
            if let maxAgeSeconds {
                try checkBind(
                    sqlite3_bind_int64(statement, 4, Int64(maxAgeSeconds))
                )
            } else {
                try checkBind(sqlite3_bind_null(statement, 4))
            }
            try checkBind(
                sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            )

            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw StoreError.step(
                    code: result,
                    message: Self.errorMessage(from: database)
                )
            }
        }
    }

    public func get(key: String) throws -> VersionRow? {
        try withLock {
            let statement = try prepareUnlocked(
                """
                SELECT KEY, VERSION, LAST_MODIFIED, MAX_AGE, FETCHED_AT
                FROM version_table
                WHERE KEY = ?
                """
            )
            defer { sqlite3_finalize(statement) }

            try bindText(key, to: statement, at: 1)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return nil
            }
            guard result == SQLITE_ROW else {
                throw StoreError.step(
                    code: result,
                    message: Self.errorMessage(from: database)
                )
            }

            guard let storedKey = columnText(statement, at: 0) else {
                throw StoreError.step(
                    code: SQLITE_CORRUPT,
                    message: "version_table.KEY unexpectedly contains NULL"
                )
            }
            let maxAge = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : Int(exactly: sqlite3_column_int64(statement, 3))

            return VersionRow(
                key: storedKey,
                version: columnText(statement, at: 1),
                lastModified: columnText(statement, at: 2),
                maxAgeSeconds: maxAge,
                fetchedAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 4)
                )
            )
        }
    }

    public func removeAll() throws {
        try withLock {
            try executeUnlocked("DELETE FROM version_table")
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func executeUnlocked(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        defer { sqlite3_free(errorPointer) }
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? Self.errorMessage(from: database)
            throw StoreError.execute(code: result, message: message)
        }
    }

    private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw StoreError.prepare(
                code: result,
                message: Self.errorMessage(from: database)
            )
        }
        return statement
    }

    private func bindOptionalText(
        _ value: String?,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        guard let value else {
            try checkBind(sqlite3_bind_null(statement, index))
            return
        }
        try bindText(value, to: statement, at: index)
    }

    private func bindText(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                Self.transientDestructor
            )
        }
        try checkBind(result)
    }

    private func checkBind(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw StoreError.bind(
                code: result,
                message: Self.errorMessage(from: database)
            )
        }
    }

    private func columnText(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private static func errorMessage(from database: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }
}
