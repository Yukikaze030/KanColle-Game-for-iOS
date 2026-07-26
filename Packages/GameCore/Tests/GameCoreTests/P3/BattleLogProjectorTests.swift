import XCTest
@testable import GameCore

final class BattleLogProjectorTests: XCTestCase {
    func testProjectsDamageSinksAndBoundedStrings() {
        var snapshot = makeSnapshot()
        snapshot.phases = [
            .init(
                kind: .shelling,
                events: [
                    .init(target: .init(component: .main, index: 0), targetIsFriendly: false, damage: 20),
                    .init(target: .init(component: .main, index: 1), targetIsFriendly: true, damage: 5)
                ],
                warnings: [.init(field: String(repeating: "f", count: 200), message: "bad")]
            )
        ]
        let entry = BattleLogProjector().project(
            snapshot: snapshot,
            startedAt: Date(timeIntervalSince1970: 100),
            enemyFleetName: String(repeating: "敵", count: 200),
            dameconSummary: String(repeating: "x", count: 600)
        )
        XCTAssertEqual(entry.phases[0].enemyDamage, 20)
        XCTAssertEqual(entry.phases[0].enemySunk, 1)
        XCTAssertEqual(entry.phases[0].friendlyDamage, 5)
        XCTAssertEqual(entry.enemyFleetName?.count, 128)
        XCTAssertEqual(entry.dameconSummary?.count, 512)
        XCTAssertLessThanOrEqual(entry.phases[0].warnings[0].count, 128)
    }

    func testLimitsPhasesAndRetainsStableNewestHundred() {
        var snapshot = makeSnapshot()
        snapshot.phases = Array(repeating: .init(kind: .aerial), count: 40)
        let projector = BattleLogProjector()
        let first = projector.project(snapshot: snapshot, startedAt: .distantPast)
        XCTAssertEqual(first.phases.count, 32)

        var entries: [BattleLogEntry] = []
        for offset in 0..<105 {
            snapshot.sessionID = UUID()
            entries = projector.inserting(
                projector.project(snapshot: snapshot, startedAt: Date(timeIntervalSince1970: Double(offset))),
                into: entries
            )
        }
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.first?.startedAt, Date(timeIntervalSince1970: 104))
        XCTAssertEqual(entries.last?.startedAt, Date(timeIntervalSince1970: 5))
    }

    func testCodableRoundTripContainsNoRawResponseOrCredentials() throws {
        let entry = BattleLogProjector().project(
            snapshot: makeSnapshot(),
            startedAt: Date(timeIntervalSince1970: 123)
        )
        let data = try JSONEncoder().encode(entry)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("api_token"))
        XCTAssertFalse(text.contains("member_id"))
        XCTAssertFalse(text.contains("rawResponse"))
        XCTAssertEqual(try JSONDecoder().decode(BattleLogEntry.self, from: data), entry)
    }

    func testReplacingSameSessionIsIdempotent() {
        let projector = BattleLogProjector()
        let entry = projector.project(snapshot: makeSnapshot(), startedAt: Date())
        XCTAssertEqual(projector.inserting(entry, into: [entry]).count, 1)
    }

    private func makeSnapshot() -> BattleSnapshot {
        BattleSnapshot(
            sessionID: UUID(),
            endpoint: BattleEndpoint("/api_req_sortie/battle"),
            kind: .sortie,
            map: .init(mapAreaID: 1, mapNumber: 1, nodeID: 1),
            formation: nil,
            friendlyMain: .init(ships: [
                ship(friendly: true, index: 0, hp: 30),
                ship(friendly: true, index: 1, hp: 25)
            ]),
            friendlyEscort: nil,
            enemyMain: .init(ships: [
                ship(friendly: false, index: 0, hp: 20),
                ship(friendly: false, index: 1, hp: 15)
            ]),
            enemyEscort: nil,
            phases: [],
            status: .completed,
            warnings: [],
            revision: 1
        )
    }

    private func ship(friendly: Bool, index: Int, hp: Int) -> BattleShipState {
        let position = BattleShipPosition(component: .main, index: index)
        return .init(
            id: friendly ? .friendlyUserShip(index + 1) : .enemyMasterShip(masterID: 100 + index, position: position),
            position: position,
            masterShipID: friendly ? nil : 100 + index,
            level: nil,
            maximumHP: hp,
            initialHP: hp,
            currentHP: hp
        )
    }
}
