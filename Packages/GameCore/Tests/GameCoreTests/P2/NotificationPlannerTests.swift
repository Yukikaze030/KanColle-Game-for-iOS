import XCTest
@testable import GameCore

final class NotificationPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStableIdentifierAndLeadTime() {
        let timer = makeTimer(id: "expedition.2", kind: .expedition, seconds: 600)
        let plan = NotificationPlanner().plan(
            timers: [timer], pendingIdentifiers: [], foreignPendingCount: 0,
            settings: .init(leadTime: 61), now: now
        )

        XCTAssertEqual(plan.toAdd.map(\.id), ["p2.timer.expedition.2"])
        XCTAssertEqual(plan.toAdd.first?.fireDate, now.addingTimeInterval(539))
        XCTAssertTrue(plan.toRemove.isEmpty)
    }

    func testCapacityKeepsNearestAndNeverDeletesForeignRequests() {
        let timers = (0..<80).map {
            makeTimer(id: "expedition.\($0)", kind: .expedition, seconds: TimeInterval(100 + $0))
        }
        let foreign = Set((0..<10).map { "foreign.\($0)" })
        let plan = NotificationPlanner().plan(
            timers: timers, pendingIdentifiers: foreign, foreignPendingCount: foreign.count,
            settings: .init(leadTime: 0), now: now
        )

        XCTAssertEqual(plan.toAdd.count, 50)
        XCTAssertLessThanOrEqual(foreign.count + plan.toAdd.count, 64)
        XCTAssertEqual(plan.toAdd.first?.timerID, "expedition.0")
        XCTAssertEqual(plan.toAdd.last?.timerID, "expedition.49")
        XCTAssertTrue(plan.toRemove.isEmpty)
    }

    func testFourIndependentKindSwitches() {
        let timers: [GameTimer] = [GameTimer.Kind.expedition, .docking, .morale, .akashi].enumerated().map {
            makeTimer(id: "kind.\($0.offset)", kind: $0.element, seconds: 600)
        }
        let settings = NotificationPlanner.Settings(
            expeditionEnabled: false, dockingEnabled: true,
            moraleEnabled: false, akashiEnabled: true, leadTime: 0
        )
        let plan = NotificationPlanner().plan(
            timers: timers, pendingIdentifiers: [], foreignPendingCount: 0,
            settings: settings, now: now
        )

        XCTAssertEqual(Set(plan.toAdd.map(\.kind)), Set<GameTimer.Kind>([.docking, .akashi]))
    }

    func testExpiredCancelledAndDisabledPendingAreRemoved() {
        let pending: Set<String> = [
            "p2.timer.expired", "p2.timer.cancelled", "p2.timer.disabled", "foreign.keep"
        ]
        let timers = [
            makeTimer(id: "expired", kind: .docking, seconds: 30),
            makeTimer(id: "cancelled", kind: .akashi, seconds: 600, cancelled: true),
            makeTimer(id: "disabled", kind: .morale, seconds: 600)
        ]
        let settings = NotificationPlanner.Settings(moraleEnabled: false, leadTime: 61)
        let plan = NotificationPlanner().plan(
            timers: timers, pendingIdentifiers: pending, foreignPendingCount: 1,
            settings: settings, now: now
        )

        XCTAssertEqual(Set(plan.toRemove), Set(["p2.timer.expired", "p2.timer.cancelled", "p2.timer.disabled"]))
        XCTAssertFalse(plan.toRemove.contains("foreign.keep"))
        XCTAssertTrue(plan.toAdd.isEmpty)
    }

    func testUnchangedMetadataIsPreservedAndChangedRequestIsReplaced() {
        let timer = makeTimer(id: "docking.1", kind: .docking, seconds: 600)
        let id = "p2.timer.docking.1"
        let unchanged = NotificationPlanner.PendingRequest(
            id: id, title: timer.title, body: timer.detail,
            fireDate: timer.completionDate.addingTimeInterval(-61)
        )
        let planner = NotificationPlanner()
        let noChange = planner.plan(
            timers: [timer], pendingRequests: [unchanged], foreignPendingCount: 0,
            settings: .init(), now: now
        )
        XCTAssertEqual(noChange, .init(toAdd: [], toRemove: []))

        let stale = NotificationPlanner.PendingRequest(
            id: id, title: timer.title, body: timer.detail,
            fireDate: timer.completionDate.addingTimeInterval(-120)
        )
        let changed = planner.plan(
            timers: [timer], pendingRequests: [stale], foreignPendingCount: 0,
            settings: .init(), now: now
        )
        XCTAssertEqual(changed.toAdd.map(\.id), [id])
        XCTAssertEqual(changed.toRemove, [id])
    }

    func testDuplicateIDKeepsNearestAndEqualDatesSortByIdentifier() {
        let timers = [
            makeTimer(id: "same", kind: .expedition, seconds: 900),
            makeTimer(id: "same", kind: .expedition, seconds: 500),
            makeTimer(id: "z", kind: .expedition, seconds: 500),
            makeTimer(id: "a", kind: .expedition, seconds: 500)
        ]
        let plan = NotificationPlanner().plan(
            timers: timers, pendingIdentifiers: [], foreignPendingCount: 0,
            settings: .init(leadTime: 0), now: now
        )

        XCTAssertEqual(plan.toAdd.map(\.id), ["p2.timer.a", "p2.timer.same", "p2.timer.z"])
        XCTAssertEqual(plan.toAdd[1].fireDate, now.addingTimeInterval(500))
    }

    func testLeadTimeClampsToZeroAndSixHundredSeconds() {
        let timer = makeTimer(id: "lead", kind: .akashi, seconds: 700)
        let planner = NotificationPlanner()
        let negative = planner.plan(
            timers: [timer], pendingIdentifiers: [], foreignPendingCount: 0,
            settings: .init(leadTime: -5), now: now
        )
        let excessive = planner.plan(
            timers: [timer], pendingIdentifiers: [], foreignPendingCount: 0,
            settings: .init(leadTime: 999), now: now
        )

        XCTAssertEqual(negative.toAdd.first?.fireDate, now.addingTimeInterval(700))
        XCTAssertEqual(excessive.toAdd.first?.fireDate, now.addingTimeInterval(100))
    }

    private func makeTimer(
        id: String,
        kind: GameTimer.Kind,
        seconds: TimeInterval,
        cancelled: Bool = false
    ) -> GameTimer {
        GameTimer(
            id: id, kind: kind, slot: nil, title: "title-\(id)", detail: "detail-\(id)",
            completionDate: now.addingTimeInterval(seconds), sourceRevision: 1,
            isCancelled: cancelled
        )
    }
}
