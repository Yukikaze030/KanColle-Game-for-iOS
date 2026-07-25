import XCTest
@testable import GameCore

final class WidgetProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testEmptyDataIsFriendlyAndRefreshesWithinFifteenMinutes() {
        let projection = WidgetProjection.make(timers: [], updatedAt: nil, now: now)
        XCTAssertTrue(projection.timers.isEmpty)
        XCTAssertFalse(projection.isStale)
        XCTAssertEqual(projection.nextRefreshDate(now: now), now.addingTimeInterval(900))
    }

    func testFiltersExpiredAndCancelledTimers() {
        let projection = WidgetProjection.make(
            timers: [
                timer("expired", at: -1),
                timer("cancelled", at: 100, cancelled: true),
                timer("active", at: 200)
            ],
            updatedAt: now,
            now: now
        )
        XCTAssertEqual(projection.timers.map(\.id), ["active"])
    }

    func testLimitsToFourNearestTimersWithStableOrdering() {
        let projection = WidgetProjection.make(
            timers: [
                timer("z", at: 100),
                timer("b", at: 50),
                timer("a", at: 50),
                timer("c", at: 150),
                timer("d", at: 200)
            ],
            updatedAt: now,
            now: now
        )
        XCTAssertEqual(projection.timers.map(\.id), ["a", "b", "z", "c"])
    }

    func testStaleSnapshotIsMarked() {
        let projection = WidgetProjection.make(
            timers: [timer("active", at: 100)],
            updatedAt: now.addingTimeInterval(-6 * 60 * 60 - 1),
            now: now
        )
        XCTAssertTrue(projection.isStale)
    }

    func testRefreshUsesNearestCompletion() {
        let projection = WidgetProjection.make(
            timers: [timer("later", at: 800), timer("first", at: 120)],
            updatedAt: now,
            now: now
        )
        XCTAssertEqual(projection.nextRefreshDate(now: now), now.addingTimeInterval(120))
    }

    private func timer(_ id: String, at offset: TimeInterval, cancelled: Bool = false) -> GameTimer {
        GameTimer(
            id: id,
            kind: .expedition,
            slot: 2,
            title: id,
            detail: "detail",
            completionDate: now.addingTimeInterval(offset),
            sourceRevision: 1,
            isCancelled: cancelled
        )
    }
}
