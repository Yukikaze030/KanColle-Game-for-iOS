import Foundation
import XCTest
@testable import GameCore

final class TimerProjectorTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testFixtureProjectsAllFourKindsWithStableIDs() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/timer_projection.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let input = try decoder.decode(TimerProjectionInput.self, from: Data(contentsOf: fixtureURL))
        var projector = TimerProjector(clock: { [baseDate] in baseDate })

        let projection = projector.project(input)

        XCTAssertEqual(Set(projection.timers.map(\.id)), ["expedition.2", "docking.1", "morale.3", "akashi"])
        XCTAssertEqual(Set(projection.timers.map(\.kind)), Set(GameTimer.Kind.allCases))
        XCTAssertEqual(projection.added, projection.timers)
        XCTAssertTrue(projection.updated.isEmpty)
        XCTAssertTrue(projection.removed.isEmpty)
        XCTAssertEqual(timer("morale.3", in: projection)?.completionDate, baseDate.addingTimeInterval(179))
        XCTAssertEqual(timer("akashi", in: projection)?.completionDate, baseDate.addingTimeInterval(1_200))
        XCTAssertTrue(timer("expedition.2", in: projection)?.detail.contains("A2") == true)
    }

    func testExpeditionOnlyAllowsFleetTwoThroughFourAndRequiresValidMission() {
        var projector = TimerProjector(clock: { [baseDate] in baseDate })
        let arrival = baseDate.addingTimeInterval(600)
        let projection = projector.project(.init(sourceRevision: 1, expeditions: [
            .init(fleetIndex: 1, fleetName: "一", missionID: 1, arrivalDate: arrival, isActive: true),
            .init(fleetIndex: 2, fleetName: "二", missionID: 0, arrivalDate: arrival, isActive: true),
            .init(fleetIndex: 3, fleetName: "三", missionID: 5, arrivalDate: nil, isActive: true),
            .init(fleetIndex: 4, fleetName: "四", missionID: 6, arrivalDate: arrival, isActive: true),
            .init(fleetIndex: 5, fleetName: "五", missionID: 7, arrivalDate: arrival, isActive: true)
        ]))

        XCTAssertEqual(projection.timers.map(\.id), ["expedition.4"])
    }

    func testExpeditionCancellationAndRestartReuseStableID() {
        let clock = TestClock(baseDate)
        var projector = TimerProjector(clock: { clock.now })
        let firstArrival = baseDate.addingTimeInterval(600)
        let secondArrival = baseDate.addingTimeInterval(900)

        _ = projector.project(.init(sourceRevision: 1, expeditions: [
            .init(fleetIndex: 2, fleetName: "第二舰队", missionID: 5, arrivalDate: firstArrival, isActive: true)
        ]))
        let cancelled = projector.project(.init(sourceRevision: 2, expeditions: [
            .init(fleetIndex: 2, fleetName: "第二舰队", missionID: 5, arrivalDate: nil, isActive: false)
        ]))
        XCTAssertEqual(cancelled.removed.map(\.id), ["expedition.2"])
        XCTAssertEqual(cancelled.removed.first?.isCancelled, true)

        let restarted = projector.project(.init(sourceRevision: 3, expeditions: [
            .init(fleetIndex: 2, fleetName: "第二舰队", missionID: 6, arrivalDate: secondArrival, isActive: true)
        ]))
        XCTAssertEqual(restarted.added.map(\.id), ["expedition.2"])
        XCTAssertEqual(restarted.timers.first?.completionDate, secondArrival)
    }

    func testDockingHighSpeedRepairAndEmptyDockRemoveTimer() {
        var projector = TimerProjector(clock: { [baseDate] in baseDate })
        let active: DockingTimerInput = .init(
            dockIndex: 1,
            state: 1,
            shipID: 10,
            shipName: "岛风",
            completionDate: baseDate.addingTimeInterval(500)
        )
        _ = projector.project(.init(sourceRevision: 1, dockings: [active]))

        let repaired = projector.project(.init(sourceRevision: 2, dockings: [
            .init(dockIndex: 1, state: 0, shipID: 0, shipName: "", completionDate: nil)
        ]))
        XCTAssertEqual(repaired.removed.map(\.id), ["docking.1"])

        _ = projector.project(.init(sourceRevision: 3, dockings: [active]))
        let empty = projector.project(.init(sourceRevision: 4, dockings: []))
        XCTAssertEqual(empty.removed.map(\.id), ["docking.1"])
    }

    func testMoraleBoundary39_38_37AllWaitOneUnit() {
        for condition in [39, 38, 37] {
            var projector = TimerProjector(clock: { [baseDate] in baseDate })
            let projection = projector.project(.init(
                sourceRevision: 1,
                morales: [.init(fleetIndex: 1, fleetName: "第一舰队", condition: condition)],
                moraleThreshold: 40
            ))
            XCTAssertEqual(
                projection.timers.first?.completionDate,
                baseDate.addingTimeInterval(TimerProjector.moraleWaitUnit),
                "cond \(condition)"
            )
        }
    }

    func testMoraleRegistrationIsIdempotentAndImprovementNeverDelays() {
        let clock = TestClock(baseDate)
        var projector = TimerProjector(clock: { clock.now })
        let fatigued = TimerProjectionInput(
            sourceRevision: 1,
            morales: [.init(fleetIndex: 1, fleetName: "第一舰队", condition: 34)]
        )
        let first = projector.project(fatigued)
        XCTAssertEqual(first.timers.first?.completionDate, baseDate.addingTimeInterval(358))

        clock.now = baseDate.addingTimeInterval(100)
        let same = projector.project(fatigued)
        XCTAssertTrue(same.added.isEmpty)
        XCTAssertTrue(same.updated.isEmpty)
        XCTAssertEqual(same.timers.first?.completionDate, first.timers.first?.completionDate)

        let improved = projector.project(.init(
            sourceRevision: 2,
            morales: [.init(fleetIndex: 1, fleetName: "第一舰队", condition: 37)]
        ))
        XCTAssertEqual(improved.timers.first?.completionDate, baseDate.addingTimeInterval(179))
        XCTAssertLessThanOrEqual(improved.timers.first!.completionDate, first.timers.first!.completionDate)
    }

    func testMoraleDecreaseResetsRegistrationAndThresholdRemovesTimer() {
        let clock = TestClock(baseDate)
        var projector = TimerProjector(clock: { clock.now })
        _ = projector.project(.init(
            sourceRevision: 1,
            morales: [.init(fleetIndex: 2, fleetName: "第二舰队", condition: 38)]
        ))

        clock.now = baseDate.addingTimeInterval(60)
        let worsened = projector.project(.init(
            sourceRevision: 2,
            morales: [.init(fleetIndex: 2, fleetName: "第二舰队", condition: 35)]
        ))
        XCTAssertEqual(worsened.timers.first?.completionDate, clock.now.addingTimeInterval(358))

        let recovered = projector.project(.init(
            sourceRevision: 3,
            morales: [.init(fleetIndex: 2, fleetName: "第二舰队", condition: 40)]
        ))
        XCTAssertTrue(recovered.timers.isEmpty)
        XCTAssertEqual(recovered.removed.map(\.id), ["morale.2"])
    }

    func testAkashiPreservesRegistrationUntilFormationChangesThenCancels() {
        let clock = TestClock(baseDate)
        var projector = TimerProjector(clock: { clock.now })
        let initial = AkashiTimerInput(hasValidFlagship: true, formationSignature: "187|1,2", detail: "2艘")
        let first = projector.project(.init(sourceRevision: 1, akashi: initial))

        clock.now = baseDate.addingTimeInterval(300)
        let same = projector.project(.init(sourceRevision: 1, akashi: initial))
        XCTAssertTrue(same.updated.isEmpty)
        XCTAssertEqual(same.timers.first?.completionDate, first.timers.first?.completionDate)

        let changed = projector.project(.init(
            sourceRevision: 2,
            akashi: .init(hasValidFlagship: true, formationSignature: "187|1,3", detail: "2艘")
        ))
        XCTAssertEqual(changed.timers.first?.completionDate, clock.now.addingTimeInterval(1_200))
        XCTAssertEqual(changed.updated.map(\.id), ["akashi"])

        let removed = projector.project(.init(
            sourceRevision: 3,
            akashi: .init(hasValidFlagship: false, formationSignature: "", detail: "")
        ))
        XCTAssertEqual(removed.removed.map(\.id), ["akashi"])
    }

    func testPastAbsoluteDatesRemainUnchangedAcrossAppRestore() {
        let past = baseDate.addingTimeInterval(-300)
        let input = TimerProjectionInput(sourceRevision: 9, expeditions: [
            .init(fleetIndex: 2, fleetName: "第二舰队", missionID: 5, arrivalDate: past, isActive: true)
        ])
        var beforeRestore = TimerProjector(clock: { [baseDate] in baseDate })
        let first = beforeRestore.project(input)

        let resumedAt = baseDate.addingTimeInterval(3_600)
        var afterRestore = TimerProjector(clock: { resumedAt })
        let restored = afterRestore.project(input)

        XCTAssertEqual(first.timers.first?.completionDate, past)
        XCTAssertEqual(restored.timers.first?.completionDate, past)
    }

    func testFourKindDiffAddUpdateAndDelete() {
        let clock = TestClock(baseDate)
        var projector = TimerProjector(clock: { clock.now })
        let arrival = baseDate.addingTimeInterval(600)
        let initial = TimerProjectionInput(
            sourceRevision: 1,
            expeditions: [.init(fleetIndex: 2, fleetName: "二", missionID: 5, arrivalDate: arrival, isActive: true)],
            dockings: [.init(dockIndex: 1, state: 1, shipID: 1, shipName: "A", completionDate: arrival)],
            morales: [.init(fleetIndex: 3, fleetName: "三", condition: 38)],
            akashi: .init(hasValidFlagship: true, formationSignature: "A")
        )
        XCTAssertEqual(projector.project(initial).added.count, 4)
        XCTAssertTrue(projector.project(initial).added.isEmpty)

        let newArrival = arrival.addingTimeInterval(100)
        let changed = TimerProjectionInput(
            sourceRevision: 2,
            expeditions: [.init(fleetIndex: 2, fleetName: "二", missionID: 6, arrivalDate: newArrival, isActive: true)],
            dockings: [.init(dockIndex: 1, state: 1, shipID: 2, shipName: "B", completionDate: newArrival)],
            morales: [.init(fleetIndex: 3, fleetName: "三", condition: 37)],
            akashi: .init(hasValidFlagship: true, formationSignature: "B")
        )
        XCTAssertEqual(Set(projector.project(changed).updated.map(\.id)), ["expedition.2", "docking.1", "morale.3", "akashi"])

        let deleted = projector.project(.init(sourceRevision: 3))
        XCTAssertEqual(Set(deleted.removed.map(\.id)), ["expedition.2", "docking.1", "morale.3", "akashi"])
        XCTAssertTrue(deleted.removed.allSatisfy(\.isCancelled))
    }

    func testNotificationLeadTimeIsClampedWithoutChangingCompletion() {
        XCTAssertEqual(TimerProjector.clampedNotificationLeadTime(-1), 0)
        XCTAssertEqual(TimerProjector.clampedNotificationLeadTime(61), 61)
        XCTAssertEqual(TimerProjector.clampedNotificationLeadTime(601), 600)

        var projector = TimerProjector(clock: { [baseDate] in baseDate })
        let completion = baseDate.addingTimeInterval(1_000)
        let projection = projector.project(.init(sourceRevision: 1, dockings: [
            .init(dockIndex: 1, state: 1, shipID: 1, shipName: "A", completionDate: completion)
        ]))
        XCTAssertEqual(projection.timers.first?.completionDate, completion)
    }

    private func timer(_ id: String, in projection: TimerProjection) -> GameTimer? {
        projection.timers.first { $0.id == id }
    }
}
