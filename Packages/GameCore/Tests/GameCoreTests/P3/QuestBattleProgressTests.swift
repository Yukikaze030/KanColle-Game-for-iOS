import Foundation
import XCTest
@testable import GameCore

final class QuestBattleProgressTests: XCTestCase {
    private let evaluator = QuestConditionEvaluator()
    private let now = ISO8601DateFormatter().date(from: "2026-07-26T06:00:00+09:00")!

    func testNodeStartAndOneSixEndCompositionRules() {
        let ordinary = node(world: 2, map: 1, node: 1, isStart: true, types: [2, 2])
        XCTAssertTrue(has(evaluator.evaluate(.nodeReached(ordinary)), questID: 214, index: 0))

        let bbvEnd = node(world: 1, map: 6, node: 14, isStart: false, types: [10, 10, 2])
        XCTAssertTrue(has(evaluator.evaluate(.nodeReached(bbvEnd)), questID: 861))
        let aoEnd = node(world: 1, map: 6, node: 17, isStart: false, types: [22, 22])
        XCTAssertTrue(has(evaluator.evaluate(.nodeReached(aoEnd)), questID: 861))

        let wrongNode = node(world: 1, map: 6, node: 13, isStart: false, types: [10, 10])
        XCTAssertFalse(has(evaluator.evaluate(.nodeReached(wrongNode)), questID: 861))
    }

    func testPracticeBranchesAndRankThresholds() {
        let c = battle(kind: .practice, rank: .c, fleet: ships(ids: [1], types: [2]))
        let cMutations = evaluator.evaluate(.battleCompleted(c))
        XCTAssertTrue(has(cMutations, questID: 303))
        XCTAssertFalse(has(cMutations, questID: 302))

        let twoCL = battle(kind: .practice, rank: .b, fleet: ships(ids: [1, 2, 3], types: [3, 3, 2]))
        let win = evaluator.evaluate(.battleCompleted(twoCL))
        for id in [302, 304, 311, 318] { XCTAssertTrue(has(win, questID: id), "quest \(id)") }

        let carriers = battle(kind: .practice, rank: .b, fleet: ships(ids: [1, 2, 3], types: [11, 7, 2]))
        XCTAssertTrue(has(evaluator.evaluate(.battleCompleted(carriers)), questID: 330))
        let carrierNotFlagship = battle(kind: .practice, rank: .b, fleet: ships(ids: [3, 1, 2], types: [2, 11, 7]))
        XCTAssertFalse(has(evaluator.evaluate(.battleCompleted(carrierNotFlagship)), questID: 330))

        let quest337 = battle(kind: .practice, rank: .s, fleet: ships(
            ids: [49, 48, 17, 18], types: [2, 2, 2, 2]
        ))
        XCTAssertTrue(has(evaluator.evaluate(.battleCompleted(quest337)), questID: 337))
        let quest339 = battle(kind: .practice, rank: .ss, fleet: ships(
            ids: [12, 368, 13, 14], types: [2, 2, 2, 2]
        ))
        XCTAssertTrue(has(evaluator.evaluate(.battleCompleted(quest339)), questID: 339))

        let fourDestroyers = battle(kind: .practice, rank: .a, fleet: ships(
            ids: [1, 2, 3, 4], types: [2, 2, 2, 2]
        ))
        XCTAssertTrue(has(evaluator.evaluate(.battleCompleted(fourDestroyers)), questID: 342))
        let threeDestroyersOneCL = battle(kind: .practice, rank: .a, fleet: ships(
            ids: [1, 2, 3, 4], types: [2, 2, 2, 3]
        ))
        XCTAssertTrue(has(evaluator.evaluate(.battleCompleted(threeDestroyersOneCL)), questID: 342))
    }

    func testBattleRanksBossAndNonBossDoNotOvercount() {
        let bossB = battle(world: 2, map: 1, boss: true, rank: .b)
        let b = evaluator.evaluate(.battleCompleted(bossB))
        for id in [210, 201, 216] { XCTAssertTrue(has(b, questID: id)) }
        XCTAssertTrue(has(b, questID: 214, index: 1))
        XCTAssertTrue(has(b, questID: 214, index: 2))
        XCTAssertFalse(has(b, questID: 214, index: 3))

        let nonBossS = battle(world: 2, map: 1, boss: false, rank: .s)
        let s = evaluator.evaluate(.battleCompleted(nonBossS))
        XCTAssertFalse(has(s, questID: 214, index: 1))
        XCTAssertFalse(has(s, questID: 214, index: 2))
        XCTAssertTrue(has(s, questID: 214, index: 3))
        XCTAssertFalse(has(s, questID: 226))

        let c = evaluator.evaluate(.battleCompleted(battle(world: 2, map: 1, boss: true, rank: .c)))
        XCTAssertTrue(has(c, questID: 210))
        XCTAssertFalse(has(c, questID: 201))
        XCTAssertFalse(has(c, questID: 216))
    }

    func testEnemyMainAndEscortSinksAndAPDuplicationSessionFlag() {
        let enemy: [QuestEnemyShipResult] = [
            enemyShip(type: 11, hp: 0, component: .main, index: 0),
            enemyShip(type: 7, hp: -1, component: .escort, index: 0),
            enemyShip(type: 15, hp: 0, component: .main, index: 1),
            enemyShip(type: 15, hp: 0, component: .escort, index: 1),
            enemyShip(type: 13, hp: 0, component: .main, index: 2),
            enemyShip(type: 14, hp: 0, component: .escort, index: 2),
            enemyShip(type: 11, hp: 1, component: .main, index: 3),
            enemyShip(type: 15, hp: nil, component: .escort, index: 3)
        ]
        let event = battle(rank: .s, enemies: enemy)
        let normal = evaluator.evaluate(.battleCompleted(event))
        XCTAssertEqual(increment(normal, questID: 211), 2)
        XCTAssertEqual(increment(normal, questID: 220), 2)
        XCTAssertEqual(increment(normal, questID: 213), 2)
        XCTAssertEqual(increment(normal, questID: 221), 2)
        XCTAssertEqual(increment(normal, questID: 212), 2)
        XCTAssertEqual(increment(normal, questID: 218), 2)
        XCTAssertEqual(increment(normal, questID: 230), 2)
        XCTAssertEqual(increment(normal, questID: 228), 2)

        let duplicated = evaluator.evaluate(
            .battleCompleted(event), flags: QuestSessionFlags(apDuplicationEnabled: true)
        )
        XCTAssertEqual(increment(duplicated, questID: 212), 4)
        XCTAssertEqual(increment(duplicated, questID: 218), 4)
        XCTAssertEqual(increment(duplicated, questID: 213), 2) // ordinary Ro transport count is not duplicated
    }

    func testFixtureCoversEveryAndroidSortieSwitchMapBranch() throws {
        let cases = try JSONDecoder().decode([ConditionCase].self, from: fixture("android_battle_switch_cases.json"))
        let expected: Set<Int> = [
            226,229,241,242,243,261,265,249,256,257,259,264,266,280,822,
            854,872,862,873,845,875,893,894,284,888,903
        ]
        XCTAssertEqual(Set(cases.map(\.questID)), expected)
        for item in cases {
            let event = battle(
                world: item.world, map: item.map, node: item.node, boss: item.boss,
                rank: BattleRank(rawValue: item.rank)!,
                fleet: ships(ids: item.fleet.map(\.id), types: item.fleet.map(\.type))
            )
            let mutations = evaluator.evaluate(.battleCompleted(event))
            XCTAssertTrue(
                has(mutations, questID: item.questID, index: item.conditionIndex),
                "missing Android branch quest \(item.questID)"
            )
        }
    }

    func testMultiMapConditionIndicesAndSetVersusIncrement() {
        let routes: [(Int, Int, Int, Int, BattleRank)] = [
            (0, 2, 4, 1, .a), (1, 6, 1, 1, .a), (2, 6, 3, 1, .a), (3, 6, 4, 1, .s)
        ]
        for (index, world, map, node, rank) in routes {
            let mutations = evaluator.evaluate(.battleCompleted(
                battle(world: world, map: map, node: node, boss: true, rank: rank)
            ))
            XCTAssertTrue(hasSet(mutations, questID: 854, index: index, value: 1))
        }

        let incrementing = evaluator.evaluate(.battleCompleted(
            battle(world: 7, map: 2, node: 7, boss: false, rank: .s)
        ))
        XCTAssertTrue(has(incrementing, questID: 893, index: 2))
        XCTAssertFalse(hasSet(incrementing, questID: 893, index: 2, value: 1))
    }

    func testReducerAppliesConditionsDeduplicatesAndLeavesServerOnlyUnknownUntouched() {
        let definitions = makeDefinitions([214: [10, 10, 10, 10], 226: [5]])
        var snapshot = makeSnapshot(definitions)
        snapshot.items[9999] = QuestListItem(
            id: 9999, category: 0, type: 0, state: 2, serverProgressFlag: 2,
            title: "unknown", detail: "", precision: .serverOnly
        )
        snapshot.tracking[9999] = QuestTrackingState(
            questID: 9999, isActive: true, counters: [], startedAt: now, precision: .serverOnly
        )
        if let tracking = snapshot.tracking[226] {
            snapshot.tracking[226] = QuestTrackingState(
                questID: 226, isActive: true, counters: tracking.counters,
                startedAt: tracking.startedAt, precision: .serverOnly
            )
        }
        var reducer = QuestProgressReducer(definitions: definitions)
        let conditional = QuestConditionalEvent.battleCompleted(
            battle(world: 2, map: 1, boss: true, rank: .s)
        )
        let first = reducer.reduce(conditional, eventID: "battle-1", occurredAt: now, snapshot: &snapshot)
        XCTAssertEqual(first, .applied(questIDs: [214]))
        XCTAssertEqual(snapshot.tracking[214]?.counters, [0, 1, 1, 1])
        XCTAssertEqual(snapshot.tracking[226]?.counters, [0])
        XCTAssertEqual(snapshot.tracking[9999]?.counters, [])
        XCTAssertEqual(snapshot.items[9999]?.serverProgressPercent, 80)
        XCTAssertEqual(
            reducer.reduce(conditional, eventID: "battle-1", occurredAt: now, snapshot: &snapshot),
            .duplicate(eventID: "battle-1")
        )
    }

    func testBattleCompletedProjectionUsesCommittedSnapshotAndBothEnemyComponents() {
        let friendly = battleShip(masterID: 101, hp: 20, component: .main, index: 0, friendly: true)
        let enemyMain = battleShip(masterID: 201, hp: 0, component: .main, index: 0, friendly: false)
        let enemyEscort = battleShip(masterID: 202, hp: 0, component: .escort, index: 0, friendly: false)
        let snapshot = BattleSnapshot(
            sessionID: UUID(), endpoint: BattleEndpoint("/api_req_combined_battle/battleresult"),
            kind: .sortie,
            map: BattleMapPosition(deckID: 1, mapAreaID: 4, mapNumber: 4, nodeID: 9, isBoss: true),
            formation: nil,
            friendlyMain: BattleFleetState(ships: [friendly]), friendlyEscort: nil,
            enemyMain: BattleFleetState(ships: [enemyMain]),
            enemyEscort: BattleFleetState(ships: [enemyEscort]), phases: [],
            status: .completed, warnings: [], revision: 4
        )
        let projected = BattleCompletedQuestEvent(
            snapshot: snapshot, rank: .a, masterShipTypes: [101: 2, 201: 11, 202: 15]
        )
        XCTAssertEqual(projected.world, 4)
        XCTAssertEqual(projected.map, 4)
        XCTAssertEqual(projected.node, 9)
        XCTAssertTrue(projected.isBoss)
        XCTAssertEqual(projected.sortieFleet.first?.shipType, 2)
        XCTAssertEqual(projected.enemies.map(\.shipType), [11, 15])
        XCTAssertEqual(projected.enemies.map(\.position.component), [.main, .escort])
    }

    private struct ConditionCase: Decodable {
        struct Ship: Decodable { let id: Int; let type: Int }
        let questID: Int
        let world: Int
        let map: Int
        let node: Int
        let boss: Bool
        let rank: String
        let fleet: [Ship]
        let conditionIndex: Int
    }

    private func battle(
        kind: BattleKind = .sortie,
        world: Int? = 1,
        map: Int? = 1,
        node: Int? = 1,
        boss: Bool = false,
        rank: BattleRank = .s,
        fleet: [QuestFleetShip] = [],
        enemies: [QuestEnemyShipResult] = []
    ) -> BattleCompletedQuestEvent {
        BattleCompletedQuestEvent(
            battleKind: kind, world: world, map: map, node: node, isBoss: boss,
            rank: rank, sortieFleet: fleet, enemies: enemies
        )
    }

    private func node(world: Int, map: Int, node: Int, isStart: Bool, types: [Int]) -> QuestNodeReachedEvent {
        QuestNodeReachedEvent(
            world: world, map: map, node: node, isStart: isStart,
            deck: ships(ids: Array(1...types.count), types: types)
        )
    }

    private func ships(ids: [Int], types: [Int]) -> [QuestFleetShip] {
        zip(ids, types).enumerated().map { index, pair in
            QuestFleetShip(
                masterShipID: pair.0, shipType: pair.1,
                position: BattleShipPosition(component: .main, index: index)
            )
        }
    }

    private func enemyShip(type: Int, hp: Int?, component: BattleFleetComponent, index: Int) -> QuestEnemyShipResult {
        QuestEnemyShipResult(
            masterShipID: 10_000 + index, shipType: type, finalHP: hp,
            position: BattleShipPosition(component: component, index: index)
        )
    }

    private func battleShip(
        masterID: Int, hp: Int, component: BattleFleetComponent, index: Int, friendly: Bool
    ) -> BattleShipState {
        let position = BattleShipPosition(component: component, index: index)
        return BattleShipState(
            id: friendly ? .friendlyUserShip(masterID) : .enemyMasterShip(masterID: masterID, position: position),
            position: position, masterShipID: masterID, level: nil,
            maximumHP: 20, initialHP: 20, currentHP: hp
        )
    }

    private func has(_ mutations: [QuestProgressMutation], questID: Int, index: Int = 0) -> Bool {
        mutations.contains {
            switch $0 {
            case let .increment(id, condition, amount): return id == questID && condition == index && amount > 0
            case let .setAtLeast(id, condition, value): return id == questID && condition == index && value > 0
            }
        }
    }

    private func hasSet(_ mutations: [QuestProgressMutation], questID: Int, index: Int, value: Int) -> Bool {
        mutations.contains { $0 == .setAtLeast(questID: questID, conditionIndex: index, value: value) }
    }

    private func increment(_ mutations: [QuestProgressMutation], questID: Int, index: Int = 0) -> Int? {
        for mutation in mutations {
            if case let .increment(id, condition, amount) = mutation, id == questID, condition == index {
                return amount
            }
        }
        return nil
    }

    private func makeDefinitions(_ targets: [Int: [Int]]) -> [Int: QuestDefinition] {
        Dictionary(uniqueKeysWithValues: targets.map {
            ($0.key, QuestDefinition(id: $0.key, resetKind: .none, conditionTargets: $0.value))
        })
    }

    private func makeSnapshot(_ definitions: [Int: QuestDefinition]) -> QuestListSnapshot {
        var snapshot = QuestListSnapshot()
        for definition in definitions.values {
            snapshot.items[definition.id] = QuestListItem(
                id: definition.id, category: 0, type: 0, state: 2,
                serverProgressFlag: 0, title: "Q\(definition.id)", detail: "", precision: .exact
            )
            snapshot.tracking[definition.id] = QuestTrackingState(
                questID: definition.id, isActive: true,
                counters: Array(repeating: 0, count: definition.conditionTargets.count),
                startedAt: now, precision: .exact
            )
        }
        return snapshot
    }

    private func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/QuestConditions/\(name)")
        return try! Data(contentsOf: url)
    }
}
