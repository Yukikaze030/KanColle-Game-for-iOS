import XCTest
@testable import GameCore

final class BattleShellingPhaseTests: XCTestCase {
    private let decoder = BattlePhaseDecoder()

    func testOpeningShellingAndNightAreDecodedInOrder() throws {
        let data = try apiData("""
        {"api_opening_taisen":{"api_at_eflag":[0],"api_df_list":[[0]],"api_damage":[[3]],"api_at_type":[0]},
         "api_hougeki1":{"api_at_eflag":[1],"api_df_list":[[0]],"api_damage":[[4]],"api_at_type":[0]},
         "api_hougeki2":{"api_at_eflag":[0],"api_df_list":[[1]],"api_damage":[[5]],"api_at_type":[0]},
         "api_hougeki3":{"api_at_eflag":[0],"api_df_list":[[2]],"api_damage":[[6]],"api_at_type":[0]},
         "api_hougeki4":{"api_at_eflag":[0],"api_df_list":[[3]],"api_damage":[[7]],"api_at_type":[0]},
         "api_hougeki":{"api_at_eflag":[1],"api_df_list":[[1]],"api_damage":[[8]],"api_at_type":[0]}}
        """)
        let phases = decoder.decodeShellingPhases(
            from: data, endpoint: BattleEndpoint("/api_req_sortie/battle")
        )
        XCTAssertEqual(phases.map(\.kind), [
            .openingAntiSubmarine, .shelling, .shelling, .shelling, .shelling, .night
        ])
        XCTAssertEqual(phases.flatMap(\.events).map(\.damage), [3, 4, 5, 6, 7, 8])
    }

    func testMultipleTargetsAndRepeatedHitsRemainSeparateEvents() throws {
        let data = try apiData("""
        {"api_hougeki1":{"api_at_eflag":[0],"api_df_list":[[0,1,1]],"api_damage":[[2.9,3,4]],"api_at_type":[100]}}
        """)
        let phase = try XCTUnwrap(decoder.decodeShellingPhases(
            from: data, endpoint: BattleEndpoint("/api_req_sortie/battle")
        ).first)
        XCTAssertEqual(phase.events, [
            .init(target: .init(component: .main, index: 0), targetIsFriendly: false, damage: 2),
            .init(target: .init(component: .main, index: 1), targetIsFriendly: false, damage: 3),
            .init(target: .init(component: .main, index: 1), targetIsFriendly: false, damage: 4)
        ])
    }

    func testAttackerFlagSelectsOpposingSideAndOldAttackKindIsAccepted() throws {
        let data = try apiData("""
        {"api_hougeki1":{"api_at_eflag":[0,1],"api_df_list":[[0],[1]],"api_damage":[[9],[10]],"api_sp_list":[2,3]}}
        """)
        let events = try XCTUnwrap(decoder.decodeShellingPhases(
            from: data, endpoint: BattleEndpoint("/api_req_sortie/battle")
        ).first).events
        XCTAssertEqual(events.map(\.targetIsFriendly), [false, true])
        XCTAssertEqual(events.map(\.target), [
            .init(component: .main, index: 0), .init(component: .main, index: 1)
        ])
    }

    func testEnemyCombinedDayLayoutsAreExplicitPerShellingRound() throws {
        let data = try apiData("""
        {"api_f_nowhps_combined":[-1,30],"api_e_nowhps_combined":[-1,40],
         "api_hougeki1":{"api_at_eflag":[0,1],"api_df_list":[[0],[1]],"api_damage":[[1],[2]],"api_at_type":[0,0]},
         "api_hougeki2":{"api_at_eflag":[0,1],"api_df_list":[[6],[7]],"api_damage":[[3],[4]],"api_at_type":[0,0]},
         "api_hougeki3":{"api_at_eflag":[0,1],"api_df_list":[[8],[9]],"api_damage":[[5],[6]],"api_at_type":[0,0]}}
        """)
        let phases = decoder.decodeShellingPhases(
            from: data, endpoint: BattleEndpoint("/api_req_combined_battle/each_battle")
        )
        XCTAssertEqual(phases[0].events.map(\.target), [
            .init(component: .main, index: 0), .init(component: .main, index: 1)
        ])
        XCTAssertEqual(phases[1].events.map(\.target), [
            .init(component: .escort, index: 0), .init(component: .escort, index: 1)
        ])
        XCTAssertEqual(phases[2].events.map(\.target), [
            .init(component: .escort, index: 2), .init(component: .escort, index: 3)
        ])
    }

    func testFriendlyFleetAndEnemyCombinedNightUseCombinedTargets() throws {
        let data = try apiData("""
        {"api_f_nowhps_combined":[-1,30],"api_e_nowhps_combined":[-1,40],
         "api_friendly_battle":{"api_hougeki":{"api_at_eflag":[0],"api_df_list":[[7]],"api_damage":[[11]],"api_at_type":[0]}},
         "api_hougeki":{"api_at_eflag":[1],"api_df_list":[[8]],"api_damage":[[12]],"api_at_type":[0]}}
        """)
        let phases = decoder.decodeShellingPhases(
            from: data, endpoint: BattleEndpoint("/api_req_combined_battle/midnight_battle")
        )
        XCTAssertEqual(phases.map(\.kind), [.friendlyFleet, .night])
        XCTAssertEqual(phases[0].events[0].target, .init(component: .escort, index: 1))
        XCTAssertEqual(phases[1].events[0].target, .init(component: .escort, index: 2))
        XCTAssertFalse(phases[0].events[0].targetIsFriendly)
        XCTAssertTrue(phases[1].events[0].targetIsFriendly)
    }

    func testEnemyCombinedActiveDeckSelectsEscortGlobalRange() throws {
        let data = try apiData("""
        {"api_f_nowhps_combined":[-1,30],"api_e_nowhps_combined":[-1,40],"api_active_deck":[2,2],
         "api_hougeki":{"api_at_eflag":[0,1],"api_df_list":[[6],[7]],"api_damage":[[13],[14]],"api_at_type":[0,0]}}
        """)
        let events = try XCTUnwrap(decoder.decodeShellingPhases(
            from: data, endpoint: BattleEndpoint("/api_req_combined_battle/ec_midnight_battle")
        ).first).events
        XCTAssertEqual(events.map(\.target), [
            .init(component: .escort, index: 0), .init(component: .escort, index: 1)
        ])
    }

    func testInvalidTargetOnlyWarnsAndOtherHitsStillApply() throws {
        let data = try apiData("""
        {"api_hougeki1":{"api_at_eflag":[0],"api_df_list":[[-1,99,0]],"api_damage":[[20,21,22]],"api_at_type":[0]}}
        """)
        let phase = try XCTUnwrap(decoder.decodeShellingPhases(
            from: data, endpoint: BattleEndpoint("/api_req_sortie/battle")
        ).first)
        XCTAssertEqual(phase.events.count, 1)
        XCTAssertEqual(phase.events[0].damage, 22)
        XCTAssertEqual(phase.warnings.count, 2)

        var snapshot = try makeSnapshot()
        var eventIDs: Set<String> = []
        let result = DamageEngine().apply(phase, to: &snapshot, appliedEventIDs: &eventIDs)
        XCTAssertTrue(result.applied)
        XCTAssertEqual(snapshot.enemyMain.ships[0].currentHP, 28)
    }

    private func makeSnapshot() throws -> BattleSnapshot {
        let data = try apiData("""
        {"api_f_maxhps":[-1,40],"api_f_nowhps":[-1,40],
         "api_e_maxhps":[-1,50],"api_e_nowhps":[-1,50],"api_ship_ke":[500]}
        """)
        return try XCTUnwrap(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_sortie/battle"), data: data
        ))
    }

    private func apiData(_ object: String) throws -> JSONValue {
        let envelope = try APIEnvelopeParser().parse(
            endpoint: "/api_req_sortie/battle",
            response: Data("svdata={\"api_result\":1,\"api_data\":\(object)}".utf8)
        )
        return try XCTUnwrap(envelope.data)
    }
}
