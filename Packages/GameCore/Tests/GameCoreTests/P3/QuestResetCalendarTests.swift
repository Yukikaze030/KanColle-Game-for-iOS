import Foundation
import XCTest
@testable import GameCore

final class QuestResetCalendarTests: XCTestCase {
    private let resetCalendar = QuestResetCalendar()

    func testDailyResetAtJapanFiveAM() {
        let started = date("2026-07-26T04:59:00+09:00")
        XCTAssertFalse(resetCalendar.isExpired(
            startedAt: started, now: date("2026-07-26T04:59:59+09:00"),
            questID: 201, resetKind: .daily
        ))
        XCTAssertTrue(resetCalendar.isExpired(
            startedAt: started, now: date("2026-07-26T05:00:00+09:00"),
            questID: 201, resetKind: .daily
        ))
        XCTAssertEqual(
            resetCalendar.nextReset(after: date("2026-07-26T05:00:00+09:00"), questID: 201, resetKind: .daily),
            date("2026-07-27T05:00:00+09:00")
        )
    }

    func testWeeklyResetIsMondayFiveAMAndCrossesYear() {
        let sunday = date("2026-12-27T23:00:00+09:00")
        XCTAssertEqual(
            resetCalendar.periodStart(containing: sunday, questID: 214, resetKind: .weekly),
            date("2026-12-21T05:00:00+09:00")
        )
        XCTAssertEqual(
            resetCalendar.periodStart(containing: date("2026-12-28T04:59:59+09:00"), questID: 214, resetKind: .weekly),
            date("2026-12-21T05:00:00+09:00")
        )
        XCTAssertEqual(
            resetCalendar.periodStart(containing: date("2026-12-28T05:00:00+09:00"), questID: 214, resetKind: .weekly),
            date("2026-12-28T05:00:00+09:00")
        )
        XCTAssertEqual(
            resetCalendar.nextReset(after: date("2026-12-28T05:00:00+09:00"), questID: 214, resetKind: .weekly),
            date("2027-01-04T05:00:00+09:00")
        )
    }

    func testMonthlyResetAtFirstDayFiveAM() {
        XCTAssertEqual(
            resetCalendar.periodStart(containing: date("2027-01-01T04:59:59+09:00"), questID: 249, resetKind: .monthly),
            date("2026-12-01T05:00:00+09:00")
        )
        XCTAssertEqual(
            resetCalendar.periodStart(containing: date("2027-01-01T05:00:00+09:00"), questID: 249, resetKind: .monthly),
            date("2027-01-01T05:00:00+09:00")
        )
    }

    func testQuarterlyBoundariesAreMarchJuneSeptemberDecember() {
        let cases = [
            ("2026-03-01T05:00:00+09:00", "2026-03-01T05:00:00+09:00"),
            ("2026-06-01T05:00:00+09:00", "2026-06-01T05:00:00+09:00"),
            ("2026-09-01T05:00:00+09:00", "2026-09-01T05:00:00+09:00"),
            ("2026-12-01T05:00:00+09:00", "2026-12-01T05:00:00+09:00"),
            ("2027-01-15T12:00:00+09:00", "2026-12-01T05:00:00+09:00")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                resetCalendar.periodStart(containing: date(input), questID: 822, resetKind: .quarterly),
                date(expected), input
            )
        }
        XCTAssertEqual(
            resetCalendar.periodStart(containing: date("2026-03-01T04:59:59+09:00"), questID: 822, resetKind: .quarterly),
            date("2025-12-01T05:00:00+09:00")
        )
    }

    func testAndroidSpecialQuestValidity() {
        for id in [211, 212] {
            XCTAssertEqual(
                resetCalendar.periodStart(containing: date("2026-07-26T04:00:00+09:00"), questID: id, resetKind: .quarterly),
                date("2026-07-26T00:00:00+09:00")
            )
        }
        for id in [311, 318, 330, 337, 339, 342] {
            XCTAssertFalse(resetCalendar.isExpired(
                startedAt: date("2026-07-26T00:01:00+09:00"),
                now: date("2026-07-26T23:59:59+09:00"),
                questID: id,
                resetKind: id == 311 || id == 318 ? .monthly : .quarterly
            ))
            XCTAssertTrue(resetCalendar.isExpired(
                startedAt: date("2026-07-26T23:59:59+09:00"),
                now: date("2026-07-27T00:00:00+09:00"),
                questID: id,
                resetKind: id == 311 || id == 318 ? .monthly : .quarterly
            ))
        }
    }

    func testTokyoCalendarIsIndependentOfSystemTimeZoneAndUSDST() {
        // These instants straddle the US spring DST date, but Tokyo remains exactly 24 hours.
        let before = date("2026-03-08T05:00:00+09:00")
        let next = resetCalendar.nextReset(after: before, questID: 201, resetKind: .daily)
        XCTAssertEqual(next?.timeIntervalSince(before), 86_400)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.component(.hour, from: before), 20)
        XCTAssertEqual(
            resetCalendar.periodStart(containing: before, questID: 201, resetKind: .daily), before
        )
    }

    func testDefinitionLoadingListSyncAndServerOnlyFallback() throws {
        let store = try makeStore()
        XCTAssertEqual(store.definition(for: 214)?.resetKind, .weekly)
        XCTAssertEqual(store.definition(for: 214)?.conditionTargets, [36, 24, 12, 6])

        let snapshot = try store.synchronize(
            apiListData: fixture("questlist_sync.json"), at: date("2026-07-26T06:00:00+09:00")
        )
        XCTAssertEqual(snapshot.items.count, 3) // -1 placeholder is ignored
        XCTAssertEqual(snapshot.items[201]?.precision, .exact)
        XCTAssertNotEqual(snapshot.items[201]?.title, "server title 201")
        XCTAssertEqual(snapshot.tracking[201]?.counters, [0])
        XCTAssertEqual(snapshot.tracking[201]?.isActive, true)
        XCTAssertNil(snapshot.tracking[411])
        XCTAssertEqual(snapshot.items[9999]?.title, "unknown server quest")
        XCTAssertEqual(snapshot.items[9999]?.detail, "server-only detail")
        XCTAssertEqual(snapshot.items[9999]?.precision, .serverOnly)
        XCTAssertEqual(snapshot.items[9999]?.serverProgressPercent, 80)
        XCTAssertEqual(snapshot.tracking[9999]?.counters, [])
    }

    func testStartStopClearAndInitialCounterCompatibility() throws {
        let store = try makeStore()
        let now = date("2026-07-26T06:00:00+09:00")
        var snapshot = try store.synchronize(apiListData: fixture("questlist_sync.json"), at: now)

        snapshot = try store.start(questID: 411, in: snapshot, at: now)
        XCTAssertEqual(snapshot.tracking[411]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[411]?.isActive, true)

        snapshot.tracking[411]?.counters[0] = 4
        snapshot = try store.stop(questID: 411, in: snapshot, at: now.addingTimeInterval(60))
        XCTAssertEqual(snapshot.tracking[411]?.counters, [4])
        XCTAssertEqual(snapshot.tracking[411]?.isActive, false)

        snapshot = try store.start(questID: 411, in: snapshot, at: now.addingTimeInterval(120))
        XCTAssertEqual(snapshot.tracking[411]?.counters, [4])

        snapshot = try store.clear(questID: 411, in: snapshot, at: now.addingTimeInterval(180))
        XCTAssertNil(snapshot.items[411])
        XCTAssertNil(snapshot.tracking[411])
        XCTAssertEqual(snapshot.completed.last?.questID, 411)
    }

    func testExpiredStoppedCountersAreDiscardedWhenRestarted() throws {
        let store = try makeStore()
        let beforeReset = date("2026-07-26T04:59:00+09:00")
        var snapshot = try store.synchronize(apiListData: fixture("questlist_sync.json"), at: beforeReset)
        snapshot.tracking[201]?.counters = [1]
        snapshot = try store.stop(questID: 201, in: snapshot, at: beforeReset)
        snapshot = try store.start(
            questID: 201,
            in: snapshot,
            at: date("2026-07-26T05:00:00+09:00")
        )
        XCTAssertEqual(snapshot.tracking[201]?.counters, [0])
        XCTAssertEqual(snapshot.tracking[201]?.startedAt, date("2026-07-26T05:00:00+09:00"))
    }

    private func makeStore() throws -> QuestDefinitionStore {
        try QuestDefinitionStore(
            trackData: fixture("quest_track_minimal.json"),
            translationData: fixture("quests_jp_minimal.json")
        )
    }

    private func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try! Data(contentsOf: url)
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
