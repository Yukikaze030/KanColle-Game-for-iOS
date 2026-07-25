import Foundation
import GameCore
import SQLite3
import WidgetKit

struct FleetTimerEntry: TimelineEntry {
    let date: Date
    let projection: WidgetProjection
    let loadFailed: Bool
}

struct FleetTimerProvider: TimelineProvider {
    private let reader: WidgetTimerReading

    init(reader: WidgetTimerReading = WidgetTimerSQLiteReader()) {
        self.reader = reader
    }

    func placeholder(in context: Context) -> FleetTimerEntry {
        let now = Date()
        return FleetTimerEntry(
            date: now,
            projection: WidgetProjection(
                timers: [
                    WidgetTimerItem(
                        id: "placeholder",
                        kind: .expedition,
                        title: "第二舰队远征",
                        detail: "海上护卫任务",
                        completionDate: now.addingTimeInterval(18 * 60)
                    )
                ],
                updatedAt: now,
                isStale: false
            ),
            loadFailed: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetTimerEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(loadEntry(at: Date()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetTimerEntry>) -> Void) {
        let now = Date()
        let entry = loadEntry(at: now)
        completion(Timeline(
            entries: [entry],
            policy: .after(entry.projection.nextRefreshDate(now: now))
        ))
    }

    private func loadEntry(at now: Date) -> FleetTimerEntry {
        do {
            let snapshot = try reader.read(now: now)
            return FleetTimerEntry(
                date: now,
                projection: WidgetProjection.make(
                    timers: snapshot.timers,
                    updatedAt: snapshot.updatedAt,
                    now: now
                ),
                loadFailed: false
            )
        } catch {
            return FleetTimerEntry(
                date: now,
                projection: WidgetProjection(timers: [], updatedAt: nil, isStale: false),
                loadFailed: true
            )
        }
    }
}

struct WidgetTimerSnapshot {
    let updatedAt: Date?
    let timers: [GameTimer]
}

protocol WidgetTimerReading {
    func read(now: Date) throws -> WidgetTimerSnapshot
}

/// Read-only App Group reader. It never migrates, repairs or writes the database.
struct WidgetTimerSQLiteReader: WidgetTimerReading {
    static let appGroupIdentifier = "group.KanColle.Game.shared"

    enum ReaderError: Error {
        case appGroupUnavailable
        case databaseUnavailable
        case queryFailed
    }

    func read(now: Date) throws -> WidgetTimerSnapshot {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw ReaderError.appGroupUnavailable
        }
        let databaseURL = base
            .appendingPathComponent("P2", isDirectory: true)
            .appendingPathComponent("game-state.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return WidgetTimerSnapshot(updatedAt: nil, timers: [])
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            throw ReaderError.databaseUnavailable
        }
        defer { sqlite3_close_v2(database) }

        sqlite3_busy_timeout(database, 250)
        guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            throw ReaderError.queryFailed
        }

        let updatedAt = try readUpdatedAt(database)
        let timers = try readTimers(database, now: now)
        return WidgetTimerSnapshot(updatedAt: updatedAt, timers: timers)
    }

    private func readUpdatedAt(_ database: OpaquePointer) throws -> Date? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT updated_at FROM current_snapshot WHERE id=1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw ReaderError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func readTimers(_ database: OpaquePointer, now: Date) throws -> [GameTimer] {
        var statement: OpaquePointer?
        let query = """
        SELECT timer_id, kind, slot, title, detail, completion_at, source_revision
        FROM timer_snapshot
        WHERE completion_at > ?
        ORDER BY completion_at ASC, timer_id ASC
        LIMIT 4
        """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ReaderError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)

        var result: [GameTimer] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW,
                  let id = text(statement, column: 0),
                  let rawKind = text(statement, column: 1),
                  let kind = GameTimer.Kind(rawValue: rawKind),
                  let title = text(statement, column: 3),
                  let detail = text(statement, column: 4) else {
                throw ReaderError.queryFailed
            }
            let slot = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(statement, 2))
            result.append(GameTimer(
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

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }
}
