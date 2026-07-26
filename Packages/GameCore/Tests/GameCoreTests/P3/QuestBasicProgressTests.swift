import Foundation
import XCTest
@testable import GameCore

final class QuestBasicProgressTests: XCTestCase {
    private let parser = APIEnvelopeParser()
    private let router = QuestEventRouter()
    private let now = ISO8601DateFormatter().date(from: "2026-07-26T06:00:00+09:00")!

    func testRouterProducesAllNavigationAndBattleSemanticEvents() {
        assertKind(route("/api_req_map/start", body: "api_deck_id=1&api_maparea_id=2&api_mapinfo_no=3")) {
            guard case .sortieStarted(deckID: 1, world: 2, map: 3) = $0 else { return false }; return true
        }
        assertKind(route("/api_req_map/next", data: ["api_maparea_id": 2, "api_mapinfo_no": 3, "api_no": 7])) {
            guard case .nodeReached(world: 2, map: 3, node: 7) = $0 else { return false }; return true
        }
        assertKind(route("/api_req_sortie/battleresult", data: ["api_win_rank": "S", "api_boss_flag": 1])) {
            guard case .battleFinished(rank: "S", isBoss: true) = $0 else { return false }; return true
        }
        assertKind(route("/api_req_practice/battle_result", data: ["api_win_rank": "A"])) {
            guard case .practiceFinished(rank: "A") = $0 else { return false }; return true
        }
        assertKind(route("/api_req_mission/start", body: "api_mission_id=37&api_deck_id=2")) {
            guard case .expeditionStarted(missionID: 37, deckID: 2) = $0 else { return false }; return true
        }
    }


    func testRouterEmitsFirstNodeAndBattleDropAsDerivedEvents() {
        let startEnvelope = APIEnvelope(
            endpoint: "/api_req_map/start", apiResult: 1, apiResultMessage: nil,
            data: .object(["api_no": .integer(5)]),
            requestParameters: ["api_deck_id": "1", "api_maparea_id": "2", "api_mapinfo_no": "3"]
        )
        let start = router.routeAll(envelope: startEnvelope, eventID: "start", occurredAt: now)
        XCTAssertEqual(start.map(\.id), ["start", "start#node"])
        XCTAssertEqual(start[1].kind, .nodeReached(world: 2, map: 3, node: 5))

        let resultEnvelope = APIEnvelope(
            endpoint: "/api_req_sortie/battleresult", apiResult: 1, apiResultMessage: nil,
            data: .object([
                "api_win_rank": .string("S"),
                "api_get_ship": .object(["api_ship_id": .integer(1001)])
            ])
        )
        let result = router.routeAll(envelope: resultEnvelope, eventID: "result", occurredAt: now)
        XCTAssertEqual(result.map(\.id), ["result", "result#ship"])
        XCTAssertEqual(result[1].kind, .shipAcquired(masterShipID: 1001))
    }

    func testRouterDecodesMissionDockSupplyAndWorkshopFixtures() throws {
        let mission = try routedFixture("mission.json", endpoint: "/api_req_mission/result")
        XCTAssertEqual(mission.kind, .expeditionFinished(missionID: 4, succeeded: true))

        let failedMission = try routedFixture("mission_failed.json", endpoint: "/api_req_mission/result")
        XCTAssertEqual(failedMission.kind, .expeditionFinished(missionID: 4, succeeded: false))

        XCTAssertEqual(
            try routedFixture("nyukyo.json", endpoint: "/api_req_nyukyo/start", body: "api_ship_id=44&api_highspeed=1").kind,
            .dockingStarted(shipID: 44, highSpeed: true)
        )
        XCTAssertEqual(
            try routedFixture("charge.json", endpoint: "/api_req_hokyu/charge", body: "api_id=1%2C2").kind,
            .supplied(shipCount: 2)
        )
        XCTAssertEqual(
            try routedFixture("createitem.json", endpoint: "/api_req_kousyou/createitem").kind,
            .itemDeveloped(attemptCount: 1, successCount: 1)
        )
        XCTAssertEqual(
            try routedFixture("createitem_failed.json", endpoint: "/api_req_kousyou/createitem").kind,
            .itemDeveloped(attemptCount: 1, successCount: 0)
        )
        XCTAssertEqual(
            try routedFixture("createitem_batch.json", endpoint: "/api_req_kousyou/createitem").kind,
            .itemDeveloped(attemptCount: 3, successCount: 2)
        )
        XCTAssertEqual(
            try routedFixture("destroyitem.json", endpoint: "/api_req_kousyou/destroyitem2", body: "api_slotitem_ids=10%2C11%2C12").kind,
            .itemDiscarded(itemInstanceIDs: [10, 11, 12])
        )
        XCTAssertEqual(
            try routedFixture("createship.json", endpoint: "/api_req_kousyou/createship", body: "api_kdock_id=2&api_large_flag=1").kind,
            .shipBuilt(dockID: 2, isLarge: true)
        )
        XCTAssertNil(try routeFixture("createship_failed.json", endpoint: "/api_req_kousyou/createship"))
        XCTAssertEqual(
            try routedFixture("destroyship.json", endpoint: "/api_req_kousyou/destroyship", body: "api_ship_id=8%2C9").kind,
            .shipDiscarded(shipInstanceIDs: [8, 9])
        )
        XCTAssertEqual(
            try routedFixture("remodel.json", endpoint: "/api_req_kousyou/remodel_slot").kind,
            .equipmentImproved(succeeded: false)
        )
        XCTAssertEqual(
            try routedFixture("powerup.json", endpoint: "/api_req_kaisou/powerup").kind,
            .modernizationCompleted(succeeded: true)
        )
        XCTAssertEqual(
            try routedFixture("getship.json", endpoint: "/api_req_kousyou/getship").kind,
            .shipAcquired(masterShipID: 1001)
        )
    }


    func testQuestLifecycleEndpointsRemainOwnedByDefinitionStore() throws {
        for (fixtureName, endpoint) in [
            ("quest_start.json", "/api_req_quest/start"),
            ("quest_stop.json", "/api_req_quest/stop"),
            ("quest_clear.json", "/api_req_quest/clearitemget")
        ] {
            XCTAssertNil(try routeFixture(fixtureName, endpoint: endpoint, body: "api_quest_id=503"))
        }
    }

    func testAndroidBasicMappingsAndConditionIndices() {
        var reducer = makeReducer()
        var snapshot = makeSnapshot()

        XCTAssertEqual(reducer.reduce(event("m4", .expeditionFinished(missionID: 4, succeeded: true)), snapshot: &snapshot),
                       .applied(questIDs: [402, 403, 404, 426, 428]))
        XCTAssertEqual(snapshot.tracking[402]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[426]?.counters, [0, 1, 0, 0])
        XCTAssertEqual(snapshot.tracking[428]?.counters, [1, 0, 0])

        _ = reducer.reduce(event("m37", .expeditionFinished(missionID: 37, succeeded: true)), snapshot: &snapshot)
        XCTAssertEqual(snapshot.tracking[410]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[411]?.counters, [1])

        _ = reducer.reduce(event("dock", .dockingStarted(shipID: 1, highSpeed: false)), snapshot: &snapshot)
        _ = reducer.reduce(event("supply", .supplied(shipCount: 6)), snapshot: &snapshot)
        _ = reducer.reduce(event("dev", .itemDeveloped(attemptCount: 3, successCount: 1)), snapshot: &snapshot)
        _ = reducer.reduce(event("discard-item", .itemDiscarded(itemInstanceIDs: [1, 2, 3])), snapshot: &snapshot)
        _ = reducer.reduce(event("build", .shipBuilt(dockID: 1, isLarge: false)), snapshot: &snapshot)
        _ = reducer.reduce(event("discard-ship", .shipDiscarded(shipInstanceIDs: [7, 8, 9])), snapshot: &snapshot)
        _ = reducer.reduce(event("improve-fail", .equipmentImproved(succeeded: false)), snapshot: &snapshot)
        _ = reducer.reduce(event("powerup", .modernizationCompleted(succeeded: true)), snapshot: &snapshot)

        XCTAssertEqual(snapshot.tracking[503]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[504]?.counters, [1]) // one charge request, not ship count
        XCTAssertEqual(snapshot.tracking[605]?.counters, [3]) // failed rolls are still attempts
        XCTAssertEqual(snapshot.tracking[607]?.counters, [3])
        XCTAssertEqual(snapshot.tracking[613]?.counters, [1]) // one batch request
        XCTAssertEqual(snapshot.tracking[606]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[608]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[609]?.counters, [3]) // each discarded ship
        XCTAssertEqual(snapshot.tracking[619]?.counters, [1]) // failed improvement is an attempt
        XCTAssertEqual(snapshot.tracking[1166]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[1167]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[702]?.counters, [1])
        XCTAssertEqual(snapshot.tracking[703]?.counters, [1])
    }

    func testFailedOperationsDoNotIncrementWhereAndroidRequiresSuccess() {
        var reducer = makeReducer()
        var snapshot = makeSnapshot()
        XCTAssertEqual(reducer.reduce(event("mission-fail", .expeditionFinished(missionID: 4, succeeded: false)), snapshot: &snapshot), .ignored)
        XCTAssertEqual(reducer.reduce(event("powerup-fail", .modernizationCompleted(succeeded: false)), snapshot: &snapshot), .ignored)
        XCTAssertEqual(snapshot.tracking[402]?.counters, [0])
        XCTAssertEqual(snapshot.tracking[702]?.counters, [0])
    }

    func testDeduplicationLRUEvictionAndSaturationPreserveServerState() {
        var reducer = QuestProgressReducer(definitions: definitions(), deduplicationCapacity: 2)
        var snapshot = makeSnapshot()
        snapshot.items[503]?.serverProgressFlag = 2
        snapshot.tracking[503]?.counters = [1]

        XCTAssertEqual(reducer.reduce(event("a", .dockingStarted(shipID: 1, highSpeed: false)), snapshot: &snapshot),
                       .applied(questIDs: [503]))
        XCTAssertEqual(snapshot.tracking[503]?.counters, [2]) // target saturation
        XCTAssertEqual(snapshot.items[503]?.serverProgressFlag, 2) // server overage/coarse state retained
        XCTAssertEqual(reducer.reduce(event("a", .dockingStarted(shipID: 1, highSpeed: false)), snapshot: &snapshot),
                       .duplicate(eventID: "a"))

        _ = reducer.reduce(event("b", .supplied(shipCount: 1)), snapshot: &snapshot)
        _ = reducer.reduce(event("c", .shipBuilt(dockID: 1, isLarge: false)), snapshot: &snapshot)
        snapshot.tracking[503]?.counters = [0]
        XCTAssertEqual(reducer.reduce(event("a", .dockingStarted(shipID: 1, highSpeed: false)), snapshot: &snapshot),
                       .applied(questIDs: [503])) // a was evicted
    }

    func testInactiveExpiredServerOnlyAndUnsupportedQuestsDoNotAdvance() {
        var definitions = definitions()
        definitions[999] = QuestDefinition(id: 999, resetKind: .none, conditionTargets: [])
        var reducer = QuestProgressReducer(definitions: definitions)
        var snapshot = makeSnapshot()
        snapshot.tracking[503]?.isActive = false
        snapshot.tracking[504]?.startedAt = now.addingTimeInterval(-7_200)
        // Force 504 to expire at the 05:00 JST boundary.
        let old = definitions[504]!
        definitions[504] = QuestDefinition(id: old.id, resetKind: .daily, conditionTargets: old.conditionTargets)
        reducer = QuestProgressReducer(definitions: definitions)
        for questID in [605, 607] {
            if let tracking = snapshot.tracking[questID] {
                snapshot.tracking[questID] = QuestTrackingState(
                    questID: tracking.questID, isActive: tracking.isActive,
                    counters: tracking.counters, startedAt: tracking.startedAt,
                    precision: .serverOnly
                )
            }
        }

        XCTAssertEqual(reducer.reduce(event("inactive", .dockingStarted(shipID: 1, highSpeed: false)), snapshot: &snapshot), .ignored)
        XCTAssertEqual(reducer.reduce(event("expired", .supplied(shipCount: 1)), snapshot: &snapshot), .ignored)
        XCTAssertEqual(reducer.reduce(event("server", .itemDeveloped(attemptCount: 1, successCount: 1)), snapshot: &snapshot), .ignored)
        XCTAssertEqual(reducer.reduce(event("unmapped", .shipAcquired(masterShipID: 1)), snapshot: &snapshot), .ignored)
    }

    private func definitions() -> [Int: QuestDefinition] {
        let targets: [Int: [Int]] = [
            402:[10], 403:[10], 404:[10], 424:[10], 426:[10,10,10,10], 428:[10,10,10],
            410:[10], 411:[10], 503:[2], 504:[2], 605:[10], 607:[10], 613:[10],
            606:[10], 608:[10], 609:[10], 619:[10], 1166:[10], 1167:[10], 702:[10], 703:[10]
        ]
        return Dictionary(uniqueKeysWithValues: targets.map {
            ($0.key, QuestDefinition(id: $0.key, resetKind: .none, conditionTargets: $0.value))
        })
    }

    private func makeReducer() -> QuestProgressReducer { QuestProgressReducer(definitions: definitions()) }

    private func makeSnapshot() -> QuestListSnapshot {
        var snapshot = QuestListSnapshot()
        for definition in definitions().values {
            snapshot.items[definition.id] = QuestListItem(
                id: definition.id, category: 0, type: definition.resetKind.rawValue,
                state: 2, serverProgressFlag: 0, title: "Q\(definition.id)", detail: "",
                precision: .exact
            )
            snapshot.tracking[definition.id] = QuestTrackingState(
                questID: definition.id, isActive: true,
                counters: Array(repeating: 0, count: definition.conditionTargets.count),
                startedAt: now, precision: .exact
            )
        }
        return snapshot
    }

    private func event(_ id: String, _ kind: QuestEvent.Kind) -> QuestEvent {
        QuestEvent(id: id, occurredAt: now, kind: kind)
    }

    private func route(_ endpoint: String, body: String? = nil, data: [String: Any]? = nil) -> QuestEvent? {
        let value = data.map(jsonValue)
        let envelope = APIEnvelope(
            endpoint: endpoint, apiResult: 1, apiResultMessage: nil, data: value,
            requestParameters: body.map(parseBody) ?? [:]
        )
        return router.route(envelope: envelope, eventID: endpoint, occurredAt: now)
    }

    private func assertKind(_ event: QuestEvent?, matches: (QuestEvent.Kind) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard let event else { return XCTFail("Missing routed event", file: file, line: line) }
        XCTAssertTrue(matches(event.kind), "Unexpected event: \(event.kind)", file: file, line: line)
    }

    private func routedFixture(_ name: String, endpoint: String, body: String? = nil) throws -> QuestEvent {
        guard let event = try routeFixture(name, endpoint: endpoint, body: body) else {
            throw NSError(domain: "QuestBasicProgressTests", code: 1)
        }
        return event
    }

    private func routeFixture(_ name: String, endpoint: String, body: String? = nil) throws -> QuestEvent? {
        let envelope = try parser.parse(
            endpoint: endpoint, response: fixture(name), requestBody: body.map { Data($0.utf8) }
        )
        return router.route(envelope: envelope, eventID: name, occurredAt: now)
    }

    private func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/QuestEvents/\(name)")
        return try! Data(contentsOf: url)
    }

    private func parseBody(_ body: String) -> [String: String] {
        let response = Data("{\"api_result\":1}".utf8)
        return try! parser.parse(endpoint: "/", response: response, requestBody: Data(body.utf8)).requestParameters
    }

    private func jsonValue(_ value: [String: Any]) -> JSONValue {
        .object(value.mapValues { value in
            switch value {
            case let value as Int: return .integer(Int64(value))
            case let value as String: return .string(value)
            case let value as Bool: return .bool(value)
            default: return .null
            }
        })
    }
}
