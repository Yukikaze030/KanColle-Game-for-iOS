import Foundation
import XCTest
@testable import GameCore

final class BattleSessionReducerTests: XCTestCase {
    func testNormalDayUsesExplicitPlanAndCapturesBeforeAfter() throws {
        var reducer = BattleSessionReducer()
        guard case let .started(snapshot, transitions) = reducer.reduce(
            envelope: try fixture("normal_day", endpoint: "/api_req_sortie/battle"),
            eventID: "normal-1", friendlyMainShipIDs: [101]
        ) else { return XCTFail("expected started") }
        XCTAssertEqual(transitions.map(\.phase.kind), [.aerial, .shelling, .torpedo])
        XCTAssertEqual(transitions.map { $0.before.enemyMain[0] }, [50, 48, 43])
        XCTAssertEqual(transitions.map { $0.after.enemyMain[0] }, [48, 43, 39])
        XCTAssertEqual(snapshot.enemyMain.ships[0].currentHP, 39)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].initialHP, 40)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 37)
        XCTAssertEqual(snapshot.revision, 1)
    }

    func testJSONKeyOrderCannotChangePhaseOrderAndNullSupportSkips() throws {
        let response = Data(#"{"api_result":1,"api_data":{"api_hougeki1":{"api_damage":[[5]],"api_df_list":[[0]],"api_at_eflag":[0]},"api_ship_ke":[501],"api_e_nowhps":[-1,50],"api_e_maxhps":[-1,50],"api_kouku":{"api_stage3":{"api_edam":[2]}},"api_f_nowhps":[-1,40],"api_f_maxhps":[-1,40],"api_opening_atack":{"api_edam":[3],"api_fdam":[0]},"api_support_info":null}}"#.utf8)
        let envelope = try APIEnvelopeParser().parse(endpoint: "/api_req_sortie/battle", response: response)
        var reducer = BattleSessionReducer()
        guard case let .started(_, transitions) = reducer.reduce(envelope: envelope) else {
            return XCTFail("expected started")
        }
        XCTAssertEqual(transitions.map(\.phase.kind), [.aerial, .openingTorpedo, .shelling])
        XCTAssertEqual(transitions.flatMap(\.phase.events).map(\.damage), [2, 3, 5])
    }

    func testAirAndRadarPlans() throws {
        var airReducer = BattleSessionReducer()
        guard case let .started(air, airTransitions) = airReducer.reduce(
            envelope: try fixture("normal_air", endpoint: "/api_req_sortie/airbattle")
        ) else { return XCTFail("expected air start") }
        XCTAssertEqual(airTransitions.map(\.phase.kind), [.aerial, .aerial])
        XCTAssertEqual(air.friendlyMain.ships[0].currentHP, 37)
        XCTAssertEqual(air.enemyMain.ships[0].currentHP, 44)

        var radarReducer = BattleSessionReducer()
        guard case let .started(radar, radarTransitions) = radarReducer.reduce(
            envelope: try fixture("radar", endpoint: "/api_req_sortie/ld_shooting")
        ) else { return XCTFail("expected radar start") }
        XCTAssertEqual(radarTransitions.map(\.phase.kind), [.airBase, .shelling])
        XCTAssertEqual(radar.enemyMain.ships[0].currentHP, 43)
    }

    func testCombinedFixturesResolveMainAndEscortTargets() throws {
        let cases: [(String, String, Int?, Int?)] = [
            ("combined_carrier", "/api_req_combined_battle/battle", 26, nil),
            ("combined_water", "/api_req_combined_battle/battle_water", 26, nil),
            ("enemy_combined", "/api_req_combined_battle/ec_battle", nil, 15),
            ("each_battle", "/api_req_combined_battle/each_battle", nil, 15)
        ]
        for (name, endpoint, friendlyEscort, enemyEscort) in cases {
            var reducer = BattleSessionReducer()
            guard case let .started(snapshot, _) = reducer.reduce(
                envelope: try fixture(name, endpoint: endpoint),
                friendlyMainShipIDs: [1], friendlyEscortShipIDs: [2]
            ) else { return XCTFail("expected start for \(endpoint)") }
            if let friendlyEscort { XCTAssertEqual(snapshot.friendlyEscort?.ships[0].currentHP, friendlyEscort, endpoint) }
            if let enemyEscort { XCTAssertEqual(snapshot.enemyEscort?.ships[0].currentHP, enemyEscort, endpoint) }
        }
    }

    func testNightContinuationReusesDayAfterHPAndAdvancesOnce() throws {
        var reducer = BattleSessionReducer()
        _ = reducer.reduce(envelope: try fixture("normal_day", endpoint: "/api_req_sortie/battle"), eventID: "day")
        let night = try envelope(endpoint: "/api_req_battle_midnight/battle", data: #"{"api_f_nowhps":[-1,40],"api_e_nowhps":[-1,50],"api_hougeki":{"api_at_eflag":[0],"api_df_list":[[0]],"api_damage":[[7]]}}"#)
        guard case let .continued(snapshot, transitions) = reducer.reduce(envelope: night, eventID: "night") else {
            return XCTFail("expected continuation")
        }
        XCTAssertEqual(transitions.map(\.phase.kind), [.night])
        XCTAssertEqual(transitions[0].before.enemyMain[0], 39)
        XCTAssertEqual(snapshot.enemyMain.ships[0].currentHP, 32)
        XCTAssertEqual(snapshot.revision, 2)
    }

    func testStandaloneSpecialMidnightInitializesFromOwnHP() throws {
        var reducer = BattleSessionReducer()
        let night = try envelope(endpoint: "/api_req_battle_midnight/sp_midnight", data: #"{"api_f_maxhps":[-1,40],"api_f_nowhps":[-1,12],"api_e_maxhps":[-1,50],"api_e_nowhps":[-1,20],"api_ship_ke":[501],"api_hougeki":{"api_at_eflag":[1],"api_df_list":[[0]],"api_damage":[[5]]}}"#)
        guard case let .started(snapshot, transitions) = reducer.reduce(envelope: night) else {
            return XCTFail("expected standalone night")
        }
        XCTAssertEqual(transitions.map(\.phase.kind), [.night])
        XCTAssertEqual(snapshot.friendlyMain.ships[0].initialHP, 12)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 7)
    }

    func testOutOfOrderAndDuplicateResponsesPreserveStateAndRevision() throws {
        var reducer = BattleSessionReducer()
        let night = try envelope(endpoint: "/api_req_battle_midnight/battle", data: #"{"api_hougeki":null}"#)
        guard case let .rejected(_, warnings) = reducer.reduce(envelope: night, eventID: "bad") else {
            return XCTFail("expected rejection")
        }
        XCTAssertTrue(warnings.contains { $0.message.contains("out-of-order") })
        XCTAssertNil(reducer.snapshot)
        guard case .rejected = reducer.reduce(envelope: night, eventID: "bad") else {
            return XCTFail("rejected event must remain retryable")
        }

        let day = try fixture("normal_day", endpoint: "/api_req_sortie/battle")
        _ = reducer.reduce(envelope: day, eventID: "same")
        let first = try XCTUnwrap(reducer.snapshot)
        XCTAssertEqual(reducer.reduce(envelope: day, eventID: "same"), .duplicate(eventID: "same"))
        XCTAssertEqual(reducer.snapshot, first)
        XCTAssertEqual(reducer.snapshot?.revision, 1)
    }

    func testNewBattleClosesOldAndResultRequiresSession() throws {
        var reducer = BattleSessionReducer()
        let result = try envelope(endpoint: "/api_req_sortie/battleresult", data: #"{}"#)
        guard case .rejected = reducer.reduce(envelope: result) else { return XCTFail("result must reject") }
        _ = reducer.reduce(envelope: try fixture("normal_day", endpoint: "/api_req_sortie/battle"), eventID: "one")
        guard case let .started(second, _) = reducer.reduce(
            envelope: try fixture("normal_air", endpoint: "/api_req_sortie/airbattle"), eventID: "two"
        ) else { return XCTFail("expected replacement") }
        XCTAssertEqual(reducer.lastClosedSession?.status, .completed)
        XCTAssertNotEqual(reducer.lastClosedSession?.sessionID, second.sessionID)
        XCTAssertEqual(second.revision, 2)
        guard case let .completed(done) = reducer.reduce(envelope: result, eventID: "result") else {
            return XCTFail("expected result completion")
        }
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.revision, 3)
    }

    func testRestoredRevisionWithoutCurrentBattleNeverRegresses() throws {
        var reducer = BattleSessionReducer(initialRevision: 41)
        guard case let .started(snapshot, _) = reducer.reduce(
            envelope: try fixture("normal_day", endpoint: "/api_req_sortie/battle"),
            eventID: "after-restore"
        ) else { return XCTFail("expected start") }
        XCTAssertEqual(snapshot.revision, 42)
    }

    private func fixture(_ name: String, endpoint: String) throws -> APIEnvelope {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BattleSession/\(name).json")
        return try APIEnvelopeParser().parse(endpoint: endpoint, response: Data(contentsOf: url))
    }

    private func envelope(endpoint: String, data: String) throws -> APIEnvelope {
        try APIEnvelopeParser().parse(
            endpoint: endpoint,
            response: Data("svdata={\"api_result\":1,\"api_data\":\(data)}".utf8)
        )
    }
}
