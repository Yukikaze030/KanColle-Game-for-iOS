import XCTest
@testable import GameCore

final class BattleSessionInitializationTests: XCTestCase {
    private let decoder = BattlePhaseDecoder()

    func testEndpointClassificationKeepsUnknownSafe() {
        XCTAssertTrue(BattleEndpoint("/kcsapi/api_req_sortie/battle").initializesSession)
        XCTAssertTrue(BattleEndpoint("/api_req_battle_midnight/battle").continuesSession)
        XCTAssertTrue(BattleEndpoint("/api_req_practice/battle_result").isResult)
        XCTAssertTrue(BattleEndpoint("/api_req_practice/battle").isPractice)
        XCTAssertNil(BattleEndpoint("/api_req_future/new_battle").known)
        XCTAssertFalse(BattleEndpoint("/api_req_future/new_battle").initializesSession)
    }

    func testSingleFleetInitializationMapsDummyHPAndFriendlyIDs() throws {
        let data = try apiData("""
        {"api_f_maxhps":[-1,40,30],"api_f_nowhps":[-1,20,30],
         "api_e_maxhps":[-1,50,45],"api_e_nowhps":[-1,50,10],
         "api_ship_ke":[501,502],"api_ship_lv":[1,2],
         "api_formation":[1,2,3]}
        """)
        let snapshot = try XCTUnwrap(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_sortie/battle"),
            data: data,
            friendlyMainShipIDs: [101, 102]
        ))

        XCTAssertEqual(snapshot.friendlyMain.ships.map(\.currentHP), [20, 30])
        XCTAssertEqual(snapshot.friendlyMain.ships.map(\.id), [.friendlyUserShip(101), .friendlyUserShip(102)])
        XCTAssertEqual(snapshot.enemyMain.ships.map(\.masterShipID), [501, 502])
        XCTAssertEqual(snapshot.enemyMain.ships.map(\.level), [1, 2])
        XCTAssertEqual(snapshot.formation, BattleFormation(friendly: 1, enemy: 2, engagement: 3))
        XCTAssertNil(snapshot.friendlyEscort)
        XCTAssertEqual(snapshot.kind, .sortie)
    }

    func testFriendlyAndEnemyCombinedFleetsUseZeroBasedPositions() throws {
        let data = try apiData("""
        {"api_f_maxhps":[-1,40],"api_f_nowhps":[-1,40],
         "api_f_maxhps_combined":[-1,35,36],"api_f_nowhps_combined":[-1,30,31],
         "api_e_maxhps":[-1,60],"api_e_nowhps":[-1,55],"api_ship_ke":[601],
         "api_e_maxhps_combined":[-1,25,26],"api_e_nowhps_combined":[-1,20,21],
         "api_ship_ke_combined":[701,702]}
        """)
        let snapshot = try XCTUnwrap(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_combined_battle/each_battle"),
            data: data,
            friendlyMainShipIDs: [101],
            friendlyEscortShipIDs: [201, 202]
        ))

        XCTAssertEqual(snapshot.friendlyEscort?.ships.map(\.position), [
            .init(component: .escort, index: 0), .init(component: .escort, index: 1)
        ])
        XCTAssertEqual(snapshot.enemyEscort?.ships.map(\.masterShipID), [701, 702])
        XCTAssertTrue(snapshot.endpoint.usesFriendlyCombinedFleet)
    }

    func testPracticeKindAndHPIsClampedToMaximum() throws {
        let data = try apiData("""
        {"api_f_maxhps":[-1,10],"api_f_nowhps":[-1,99],
         "api_e_maxhps":[-1,12],"api_e_nowhps":[-1,12],"api_ship_ke":[8]}
        """)
        let snapshot = try XCTUnwrap(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_practice/battle"),
            data: data,
            friendlyMainShipIDs: [1]
        ))
        XCTAssertEqual(snapshot.kind, .practice)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 10)
    }

    func testMalformedValuesWarnAndValidShipsStillDecode() throws {
        let data = try apiData("""
        {"api_f_maxhps":[-1,40,30,20,10,9,8,7],
         "api_f_nowhps":[-1,40,"NaN",20,10,9,8,7],
         "api_e_maxhps":[-1,50],"api_e_nowhps":[-1,50],"api_ship_ke":[5]}
        """)
        let snapshot = try XCTUnwrap(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_sortie/battle"),
            data: data
        ))
        XCTAssertEqual(snapshot.friendlyMain.ships.count, 5)
        XCTAssertTrue(snapshot.warnings.contains { $0.message.contains("non-integer") })
        XCTAssertTrue(snapshot.warnings.contains { $0.message.contains("truncated") })
    }

    func testMissingRequiredFleetReturnsNilInsteadOfCrashing() throws {
        let data = try apiData(#"{"api_f_maxhps":[],"api_f_nowhps":[]}"#)
        XCTAssertNil(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_sortie/battle"),
            data: data
        ))
        XCTAssertNil(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_future/new"),
            data: data
        ))
    }

    func testMapStartDecodesRequestAndBossNode() throws {
        let envelope = try APIEnvelopeParser().parse(
            endpoint: "/api_req_map/start",
            response: Data("""
            svdata={"api_result":1,"api_data":{"api_no":5,"api_bosscell_no":5,"api_event_id":4,"api_event_kind":1}}
            """.utf8),
            requestBody: Data("api_deck_id=2&api_maparea_id=46&api_mapinfo_no=7&api_token=secret".utf8)
        )
        let map = try XCTUnwrap(decoder.mapPosition(from: envelope))
        XCTAssertEqual(map.deckID, 2)
        XCTAssertEqual(map.mapAreaID, 46)
        XCTAssertEqual(map.mapNumber, 7)
        XCTAssertEqual(map.nodeID, 5)
        XCTAssertTrue(map.isBoss)
        XCTAssertNil(envelope.requestParameters["api_token"])
    }

    func testCodableRoundTripPreservesAssociatedIdentity() throws {
        let data = try apiData("""
        {"api_f_maxhps":[-1,10],"api_f_nowhps":[-1,10],
         "api_e_maxhps":[-1,12],"api_e_nowhps":[-1,12],"api_ship_ke":[8]}
        """)
        let snapshot = try XCTUnwrap(decoder.initializeSession(
            endpoint: BattleEndpoint("/api_req_sortie/battle"),
            data: data,
            friendlyMainShipIDs: [99]
        ))
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(BattleSnapshot.self, from: encoded), snapshot)
    }

    private func apiData(_ object: String) throws -> JSONValue {
        let envelope = try APIEnvelopeParser().parse(
            endpoint: "/api_req_sortie/battle",
            response: Data("svdata={\"api_result\":1,\"api_data\":\(object)}".utf8)
        )
        return try XCTUnwrap(envelope.data)
    }
}
