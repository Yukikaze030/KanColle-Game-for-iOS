import Foundation
import XCTest
@testable import GameCore

final class DameconResolverTests: XCTestCase {
    func testRepairTeamInNormalSlotRestoresFloorTwentyPercent() throws {
        var reducer = BattleSessionReducer()
        guard case let .started(snapshot, _) = reducer.reduce(
            envelope: try fixture("repair_team", endpoint: "/api_req_sortie/battle"),
            eventID: "repair-team",
            fleetSnapshot: fleet(
                main: [ship(id: 101, hp: 1, maxHP: 41, slots: [501])],
                items: [item(id: 501, masterID: 42)]
            ),
            sortieDeckID: 1
        ) else { return XCTFail("expected battle") }

        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 8)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].damecon?.consumed, true)
        XCTAssertEqual(snapshot.dameconActivations, [
            .init(
                itemInstanceID: 501,
                masterItemID: 42,
                ship: .init(component: .main, index: 0),
                phase: .shelling,
                restoredHP: 8
            )
        ])
    }

    func testGoddessInExpansionSlotRestoresFullHP() throws {
        var reducer = BattleSessionReducer()
        guard case let .started(snapshot, _) = reducer.reduce(
            envelope: try fixture("goddess", endpoint: "/api_req_sortie/battle"),
            fleetSnapshot: fleet(
                main: [ship(id: 101, hp: 1, maxHP: 37, extra: 601)],
                items: [item(id: 601, masterID: 43)]
            ),
            sortieDeckID: 1
        ) else { return XCTFail("expected battle") }

        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 37)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].damecon?.triggeredPhase, .shelling)
        XCTAssertEqual(snapshot.dameconActivations.first?.masterItemID, 43)
    }

    func testSamePhaseMultiHitCanActivateOnlyOnceThenSink() throws {
        var snapshot = try initializedSnapshot(hp: 1, maxHP: 40)
        snapshot.friendlyMain.ships[0].damecon = .init(
            itemInstanceID: 701, kind: .repairTeam
        )
        let phase = BattlePhaseResult(kind: .shelling, events: [
            damage(1), damage(100)
        ])
        var ids: Set<String> = []

        DamageEngine().apply(phase, to: &snapshot, eventID: "phase", appliedEventIDs: &ids)

        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 0)
        XCTAssertEqual(snapshot.dameconActivations.count, 1)
        XCTAssertEqual(
            DameconResolver.risk(for: snapshot.friendlyMain.ships[0], battleKind: .sortie),
            .sunk
        )
    }

    func testPracticeDoesNotConsumeOrRestoreDamecon() throws {
        var snapshot = try initializedSnapshot(
            endpoint: "/api_req_practice/battle", hp: 1, maxHP: 40
        )
        snapshot.friendlyMain.ships[0].damecon = .init(
            itemInstanceID: 801, kind: .goddess
        )
        var ids: Set<String> = []

        DamageEngine().apply(
            .init(kind: .shelling, events: [damage(1)]),
            to: &snapshot,
            appliedEventIDs: &ids
        )

        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 0)
        XCTAssertEqual(snapshot.friendlyMain.ships[0].damecon?.consumed, false)
        XCTAssertTrue(snapshot.dameconActivations.isEmpty)
        XCTAssertEqual(
            DameconResolver.risk(for: snapshot.friendlyMain.ships[0], battleKind: .practice),
            .safe
        )
    }

    func testLethalDamageWithoutDameconStaysSunk() throws {
        var snapshot = try initializedSnapshot(hp: 1, maxHP: 40)
        var ids: Set<String> = []

        DamageEngine().apply(
            .init(kind: .shelling, events: [damage(1)]),
            to: &snapshot,
            appliedEventIDs: &ids
        )

        XCTAssertEqual(snapshot.friendlyMain.ships[0].currentHP, 0)
        XCTAssertTrue(snapshot.dameconActivations.isEmpty)
        XCTAssertEqual(
            DameconResolver.risk(for: snapshot.friendlyMain.ships[0], battleKind: .sortie),
            .sunk
        )
    }

    func testDuplicateResponseDoesNotReactivate() throws {
        let battle = try fixture("repair_team", endpoint: "/api_req_sortie/battle")
        var reducer = BattleSessionReducer()
        let fleet = fleet(
            main: [ship(id: 101, hp: 1, maxHP: 41, slots: [501])],
            items: [item(id: 501, masterID: 42)]
        )
        _ = reducer.reduce(
            envelope: battle, eventID: "same", fleetSnapshot: fleet, sortieDeckID: 1
        )
        XCTAssertEqual(
            reducer.reduce(
                envelope: battle, eventID: "same", fleetSnapshot: fleet, sortieDeckID: 1
            ),
            .duplicate(eventID: "same")
        )
        XCTAssertEqual(reducer.snapshot?.dameconActivations.count, 1)
        XCTAssertEqual(reducer.snapshot?.revision, 1)
    }

    func testCombinedEscortLoadoutAndGlobalRetreatMapping() throws {
        var reducer = BattleSessionReducer()
        let fleet = fleet(
            main: [ship(id: 101, hp: 40, maxHP: 40)],
            escort: [
                ship(id: 201, hp: 30, maxHP: 30),
                ship(id: 202, hp: 7, maxHP: 30, slots: [901])
            ],
            items: [item(id: 901, masterID: 42)]
        )
        _ = reducer.reduce(
            envelope: try combinedBattleEnvelope(),
            eventID: "combined",
            fleetSnapshot: fleet,
            sortieDeckID: 1
        )
        XCTAssertEqual(reducer.snapshot?.friendlyEscort?.ships[1].damecon?.kind, .repairTeam)
        XCTAssertEqual(
            DameconResolver.risk(
                for: try XCTUnwrap(reducer.snapshot?.friendlyEscort?.ships[1]),
                battleKind: .sortie
            ),
            .heavyDamagedWithDamecon
        )

        guard case let .continued(snapshot, _) = reducer.reduce(
            envelope: try fixture(
                "retreat_combined",
                endpoint: "/api_req_combined_battle/goback_port"
            ),
            eventID: "retreat"
        ) else { return XCTFail("expected retreat update") }

        XCTAssertEqual(snapshot.friendlyMain.ships[0].escaped, true)
        XCTAssertEqual(snapshot.friendlyEscort?.ships[1].escaped, true)
        XCTAssertEqual(
            DameconResolver.risk(
                for: try XCTUnwrap(snapshot.friendlyEscort?.ships[1]),
                battleKind: .sortie
            ),
            .safe
        )
        XCTAssertFalse(
            DameconResolver.retreatWarnings(in: snapshot)
                .contains { $0.message.contains("escort.1") }
        )
    }

    func testCombinedEscortDameconActivationUsesEscortPosition() throws {
        var reducer = BattleSessionReducer()
        _ = reducer.reduce(
            envelope: try combinedBattleEnvelope(),
            fleetSnapshot: fleet(
                main: [ship(id: 101, hp: 40, maxHP: 40)],
                escort: [
                    ship(id: 201, hp: 30, maxHP: 30),
                    ship(id: 202, hp: 7, maxHP: 30, slots: [901])
                ],
                items: [item(id: 901, masterID: 42)]
            ),
            sortieDeckID: 1
        )
        var snapshot = try XCTUnwrap(reducer.snapshot)
        var ids: Set<String> = []
        let escortDamage = DamageEvent(
            target: .init(component: .escort, index: 1),
            targetIsFriendly: true,
            damage: 7
        )

        DamageEngine().apply(
            .init(kind: .torpedo, events: [escortDamage]),
            to: &snapshot,
            appliedEventIDs: &ids
        )

        XCTAssertEqual(snapshot.friendlyEscort?.ships[1].currentHP, 6)
        XCTAssertEqual(snapshot.dameconActivations.first?.ship, .init(component: .escort, index: 1))
        XCTAssertEqual(snapshot.dameconActivations.first?.phase, .torpedo)
    }

    func testRetreatRiskDistinguishesEveryStateAndEscapedExclusion() {
        var safe = battleShip(hp: 30, maxHP: 40)
        var withDamecon = battleShip(hp: 10, maxHP: 40)
        withDamecon.damecon = .init(itemInstanceID: 1, kind: .repairTeam)
        var heavy = battleShip(hp: 10, maxHP: 40)
        heavy.damecon = .init(itemInstanceID: 2, kind: .repairTeam, consumed: true)
        let sunk = battleShip(hp: 0, maxHP: 40)
        let unknown = battleShip(hp: 0, maxHP: 0)
        safe.escaped = true

        XCTAssertEqual(DameconResolver.risk(for: safe, battleKind: .sortie), .safe)
        XCTAssertEqual(DameconResolver.risk(for: withDamecon, battleKind: .sortie), .heavyDamagedWithDamecon)
        XCTAssertEqual(DameconResolver.risk(for: heavy, battleKind: .sortie), .heavyDamaged)
        XCTAssertEqual(DameconResolver.risk(for: sunk, battleKind: .sortie), .sunk)
        XCTAssertEqual(DameconResolver.risk(for: unknown, battleKind: .sortie), .unknown)
    }

    private func fixture(_ name: String, endpoint: String) throws -> APIEnvelope {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Damecon/\(name).json")
        return try APIEnvelopeParser().parse(endpoint: endpoint, response: Data(contentsOf: url))
    }

    private func initializedSnapshot(
        endpoint: String = "/api_req_sortie/battle",
        hp: Int,
        maxHP: Int
    ) throws -> BattleSnapshot {
        let data = """
        {"api_f_maxhps":[-1,\(maxHP)],"api_f_nowhps":[-1,\(hp)],
         "api_e_maxhps":[-1,20],"api_e_nowhps":[-1,20],"api_ship_ke":[501]}
        """
        let envelope = try APIEnvelopeParser().parse(
            endpoint: endpoint,
            response: Data("svdata={\"api_result\":1,\"api_data\":\(data)}".utf8)
        )
        return try XCTUnwrap(BattlePhaseDecoder().initializeSession(
            endpoint: BattleEndpoint(endpoint),
            data: try XCTUnwrap(envelope.data),
            friendlyMainShipIDs: [101]
        ))
    }

    private func combinedBattleEnvelope() throws -> APIEnvelope {
        let data = """
        {"api_f_maxhps":[-1,40],"api_f_nowhps":[-1,40],
         "api_f_maxhps_combined":[-1,30,30],"api_f_nowhps_combined":[-1,30,7],
         "api_e_maxhps":[-1,20],"api_e_nowhps":[-1,20],"api_ship_ke":[501]}
        """
        return try APIEnvelopeParser().parse(
            endpoint: "/api_req_combined_battle/battle",
            response: Data("svdata={\"api_result\":1,\"api_data\":\(data)}".utf8)
        )
    }

    private func damage(_ amount: Int) -> DamageEvent {
        .init(
            target: .init(component: .main, index: 0),
            targetIsFriendly: true,
            damage: amount
        )
    }

    private func battleShip(hp: Int, maxHP: Int) -> BattleShipState {
        .init(
            id: .friendlyUserShip(101),
            position: .init(component: .main, index: 0),
            masterShipID: nil,
            level: 1,
            maximumHP: maxHP,
            initialHP: hp,
            currentHP: hp
        )
    }

    private func fleet(
        main: [UserShip],
        escort: [UserShip] = [],
        items: [UserSlotItem]
    ) -> FleetSnapshot {
        var decks: [Int: FleetDeck] = [
            1: .init(id: 1, name: "Main", shipIDs: main.map(\.id), expedition: nil)
        ]
        if !escort.isEmpty {
            decks[2] = .init(id: 2, name: "Escort", shipIDs: escort.map(\.id), expedition: nil)
        }
        return FleetSnapshot(
            ships: Dictionary(uniqueKeysWithValues: (main + escort).map { ($0.id, $0) }),
            slotItems: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            decks: decks,
            combinedFleetType: escort.isEmpty ? 0 : 1
        )
    }

    private func ship(
        id: Int,
        hp: Int,
        maxHP: Int,
        slots: [Int] = [],
        extra: Int? = nil
    ) -> UserShip {
        .init(
            id: id,
            masterShipID: id + 1000,
            level: 99,
            currentHP: hp,
            maximumHP: maxHP,
            condition: 49,
            slotItemIDs: slots,
            aircraftCounts: [],
            extraSlotItemID: extra,
            locked: true
        )
    }

    private func item(id: Int, masterID: Int) -> UserSlotItem {
        .init(
            id: id,
            masterSlotItemID: masterID,
            improvementLevel: 0,
            aircraftProficiency: 0,
            locked: true
        )
    }
}
