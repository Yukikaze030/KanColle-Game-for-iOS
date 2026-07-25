import XCTest
@testable import GameCore

final class BattleVectorPhaseTests: XCTestCase {
    private let decoder = BattlePhaseDecoder()

    func testVectorPhasesFollowExplicitOrder() throws {
        let data = try apiData("""
        {"api_air_base_injection":{"api_stage3":{"api_edam":[1,0]}},
         "api_injection_kouku":{"api_stage3":{"api_edam":[2,0]}},
         "api_air_base_attack":[{"api_stage3":{"api_edam":[3,0]}}],
         "api_kouku":{"api_stage3":{"api_fdam":[4,0],"api_edam":[5,0]}},
         "api_kouku2":{"api_stage3":{"api_edam":[6,0]}},
         "api_support_info":{"api_support_hourai":{"api_damage":[7,0]}},
         "api_opening_atack":{"api_fdam":[8,0],"api_edam":[9,0]},
         "api_raigeki":{"api_fdam":[10,0],"api_edam":[11,0]}}
        """)
        let phases = decoder.decodeVectorPhases(from: data)
        XCTAssertEqual(phases.map(\.kind), [
            .airBase, .aerial, .airBase, .aerial, .aerial,
            .support, .openingTorpedo, .torpedo
        ])
        XCTAssertEqual(phases.flatMap(\.events).map(\.damage), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    }

    func testAirStageMapsMainEscortAndCombinedStage() throws {
        let data = try apiData("""
        {"api_kouku":{
          "api_stage3":{"api_fdam":[1,0,0,0,0,0,2],"api_edam":[3,0,0,0,0,0,4]},
          "api_stage3_combined":{"api_fdam":[5],"api_edam":[6]}
        }}
        """)
        let events = try XCTUnwrap(decoder.decodeVectorPhases(from: data).first).events
        XCTAssertEqual(events, [
            .init(target: .init(component: .main, index: 0), targetIsFriendly: true, damage: 1),
            .init(target: .init(component: .escort, index: 0), targetIsFriendly: true, damage: 2),
            .init(target: .init(component: .main, index: 0), targetIsFriendly: false, damage: 3),
            .init(target: .init(component: .escort, index: 0), targetIsFriendly: false, damage: 4),
            .init(target: .init(component: .escort, index: 0), targetIsFriendly: true, damage: 5),
            .init(target: .init(component: .escort, index: 0), targetIsFriendly: false, damage: 6)
        ])
    }

    func testFloatDamageTruncatesTowardZeroAndInvalidValuesWarn() throws {
        let data = try apiData("""
        {"api_raigeki":{"api_fdam":[3.9,-2.2,"NaN",null],"api_edam":["4.8"]}}
        """)
        let phase = try XCTUnwrap(decoder.decodeVectorPhases(from: data).first)
        XCTAssertEqual(phase.events.map(\.damage), [3, 4])
        XCTAssertEqual(phase.warnings.count, 1)
    }

    func testDamageEngineAppliesBothSidesAndNeverDropsBelowZero() throws {
        var snapshot = try makeCombinedSnapshot()
        let phase = BattlePhaseResult(kind: .aerial, events: [
            .init(target: .init(component: .main, index: 0), targetIsFriendly: true, damage: 99),
            .init(target: .init(component: .escort, index: 0), targetIsFriendly: false, damage: 4)
        ])
        var eventIDs: Set<String> = []
        let result = DamageEngine().apply(
            phase, to: &snapshot, eventID: "air.1", appliedEventIDs: &eventIDs
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 0)
        XCTAssertEqual(snapshot.enemyEscort?.ships[0].currentHP, 16)
    }

    func testDamageEngineEventIDIsIdempotent() throws {
        var snapshot = try makeCombinedSnapshot()
        let phase = BattlePhaseResult(kind: .torpedo, events: [
            .init(target: .init(component: .main, index: 0), targetIsFriendly: false, damage: 5)
        ])
        var eventIDs: Set<String> = []
        XCTAssertTrue(DamageEngine().apply(
            phase, to: &snapshot, eventID: "same", appliedEventIDs: &eventIDs
        ).applied)
        XCTAssertFalse(DamageEngine().apply(
            phase, to: &snapshot, eventID: "same", appliedEventIDs: &eventIDs
        ).applied)
        XCTAssertEqual(snapshot.enemyMain.ships[0].currentHP, 45)
        XCTAssertEqual(snapshot.phases.filter { $0.kind == .torpedo }.count, 1)
    }

    func testOutOfRangeTargetWarnsButOtherDamageApplies() throws {
        var snapshot = try makeCombinedSnapshot()
        let phase = BattlePhaseResult(kind: .support, events: [
            .init(target: .init(component: .main, index: 99), targetIsFriendly: false, damage: 5),
            .init(target: .init(component: .main, index: 0), targetIsFriendly: false, damage: 6)
        ])
        var eventIDs: Set<String> = []
        let result = DamageEngine().apply(phase, to: &snapshot, appliedEventIDs: &eventIDs)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(snapshot.enemyMain.ships[0].currentHP, 44)
    }

    private func makeCombinedSnapshot() throws -> BattleSnapshot {
        let data = try apiData("""
        {"api_f_maxhps":[-1,40],"api_f_nowhps":[-1,40],
         "api_f_maxhps_combined":[-1,30],"api_f_nowhps_combined":[-1,30],
         "api_e_maxhps":[-1,50],"api_e_nowhps":[-1,50],"api_ship_ke":[500],
         "api_e_maxhps_combined":[-1,20],"api_e_nowhps_combined":[-1,20],
         "api_ship_ke_combined":[600]}
        """)
        return try XCTUnwrap(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_combined_battle/each_battle"),
            data: data,
            friendlyMainShipIDs: [1],
            friendlyEscortShipIDs: [2]
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
