import Foundation

public struct QuestFleetShip: Codable, Equatable, Sendable {
    public let masterShipID: Int?
    public let shipType: Int?
    public let position: BattleShipPosition

    public init(masterShipID: Int?, shipType: Int?, position: BattleShipPosition) {
        self.masterShipID = masterShipID
        self.shipType = shipType
        self.position = position
    }
}

public struct QuestEnemyShipResult: Codable, Equatable, Sendable {
    public let masterShipID: Int?
    public let shipType: Int?
    public let finalHP: Int?
    public let position: BattleShipPosition

    public init(masterShipID: Int?, shipType: Int?, finalHP: Int?, position: BattleShipPosition) {
        self.masterShipID = masterShipID
        self.shipType = shipType
        self.finalHP = finalHP
        self.position = position
    }
}

/// Immutable deck snapshot captured when map start/next arrives. It must never read the
/// current mutable port fleet because composition may change after returning to port.
public struct QuestNodeReachedEvent: Codable, Equatable, Sendable {
    public let world: Int
    public let map: Int
    public let node: Int
    public let isStart: Bool
    public let deck: [QuestFleetShip]

    public init(world: Int, map: Int, node: Int, isStart: Bool, deck: [QuestFleetShip]) {
        self.world = world
        self.map = map
        self.node = node
        self.isStart = isStart
        self.deck = deck
    }
}

/// Battle result projection consumed by quest tracking. It is constructed from the
/// committed battle snapshot and rank model, with master ship types resolved once at
/// the boundary rather than from mutable global state inside the reducer.
public struct BattleCompletedQuestEvent: Equatable, Sendable {
    public let battleKind: BattleKind
    public let world: Int?
    public let map: Int?
    public let node: Int?
    public let isBoss: Bool
    public let rank: BattleRank
    public let sortieFleet: [QuestFleetShip]
    public let enemies: [QuestEnemyShipResult]

    public init(
        snapshot: BattleSnapshot,
        rank: BattleRank,
        masterShipTypes: [Int: Int]
    ) {
        self.battleKind = snapshot.kind
        self.world = snapshot.map?.mapAreaID
        self.map = snapshot.map?.mapNumber
        self.node = snapshot.map?.nodeID
        self.isBoss = snapshot.map?.isBoss ?? false
        self.rank = rank
        self.sortieFleet = Self.fleetShips(
            snapshot.friendlyMain.ships + (snapshot.friendlyEscort?.ships ?? []),
            masterShipTypes: masterShipTypes
        )
        self.enemies = Self.enemyShips(
            snapshot.enemyMain.ships + (snapshot.enemyEscort?.ships ?? []),
            masterShipTypes: masterShipTypes
        )
    }

    public init(
        battleKind: BattleKind = .sortie,
        world: Int?,
        map: Int?,
        node: Int?,
        isBoss: Bool,
        rank: BattleRank,
        sortieFleet: [QuestFleetShip],
        enemies: [QuestEnemyShipResult]
    ) {
        self.battleKind = battleKind
        self.world = world
        self.map = map
        self.node = node
        self.isBoss = isBoss
        self.rank = rank
        self.sortieFleet = sortieFleet
        self.enemies = enemies
    }

    private static func fleetShips(
        _ ships: [BattleShipState],
        masterShipTypes: [Int: Int]
    ) -> [QuestFleetShip] {
        ships.map {
            QuestFleetShip(
                masterShipID: $0.masterShipID,
                shipType: $0.masterShipID.flatMap { masterShipTypes[$0] },
                position: $0.position
            )
        }
    }

    private static func enemyShips(
        _ ships: [BattleShipState],
        masterShipTypes: [Int: Int]
    ) -> [QuestEnemyShipResult] {
        ships.map {
            QuestEnemyShipResult(
                masterShipID: $0.masterShipID,
                shipType: $0.masterShipID.flatMap { masterShipTypes[$0] },
                finalHP: $0.currentHP,
                position: $0.position
            )
        }
    }
}

public enum QuestConditionalEvent: Equatable, Sendable {
    case nodeReached(QuestNodeReachedEvent)
    case battleCompleted(BattleCompletedQuestEvent)
}

/// Session-scoped compatibility flags. Android stored `ap_dup_flag` globally; keeping
/// it here prevents one sortie or account from leaking duplication state into another.
public struct QuestSessionFlags: Codable, Equatable, Sendable {
    public var apDuplicationEnabled: Bool

    public init(apDuplicationEnabled: Bool = false) {
        self.apDuplicationEnabled = apDuplicationEnabled
    }
}

public enum QuestProgressMutation: Equatable, Sendable {
    case increment(questID: Int, conditionIndex: Int, amount: Int)
    case setAtLeast(questID: Int, conditionIndex: Int, value: Int)

    public var questID: Int {
        switch self {
        case let .increment(questID, _, _), let .setAtLeast(questID, _, _): return questID
        }
    }
}

public struct QuestConditionEvaluator: Sendable {
    private enum RankRequirement: Sendable {
        case any, win, good, s

        func accepts(_ rank: BattleRank) -> Bool {
            switch self {
            case .any: return true
            case .win: return [.ss, .s, .a, .b].contains(rank)
            case .good: return [.ss, .s, .a].contains(rank)
            case .s: return rank == .ss || rank == .s
            }
        }
    }

    private struct MapRule: Sendable {
        let questID: Int
        let world: Int
        let map: Int?
        let minimumMap: Int?
        let node: Int?
        let boss: Bool
        let rank: RankRequirement
        let fleet: FleetPredicate
    }

    private struct MultiMapRule: Sendable {
        let questID: Int
        let conditionIndex: Int
        let world: Int
        let map: Int
        let node: Int?
        let boss: Bool
        let rank: RankRequirement
        let mode: MultiMode
        let fleet: FleetPredicate
    }

    private enum MultiMode: Sendable { case setOne, increment }

    private enum FleetPredicate: Sendable {
        case any
        case quest249
        case quest257
        case quest259
        case quest264
        case quest266
        case quest280
        case quest862
        case quest875
        case quest894
        case quest284
        case quest888
        case quest903
    }

    private enum ShipType {
        static let de = 1, dd = 2, cl = 3, ca = 5, cvl = 7, bbv = 10
        static let cv = 11, ss = 13, ssv = 14, ap = 15, av = 16, cvb = 18, ao = 22
        static let carriers: Set<Int> = [cvl, cv, cvb]
        static let submarines: Set<Int> = [ss, ssv]
    }

    private static let simpleMapRules: [MapRule] = [
        .init(questID: 226, world: 2, map: nil, minimumMap: nil, node: nil, boss: true, rank: .win, fleet: .any),
        .init(questID: 229, world: 4, map: nil, minimumMap: nil, node: nil, boss: true, rank: .win, fleet: .any),
        .init(questID: 241, world: 3, map: nil, minimumMap: 3, node: nil, boss: true, rank: .win, fleet: .any),
        .init(questID: 242, world: 4, map: 4, minimumMap: nil, node: nil, boss: true, rank: .good, fleet: .any),
        .init(questID: 243, world: 5, map: 2, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .any),
        .init(questID: 261, world: 1, map: 5, minimumMap: nil, node: nil, boss: true, rank: .good, fleet: .any),
        .init(questID: 265, world: 1, map: 5, minimumMap: nil, node: nil, boss: true, rank: .good, fleet: .any),
        .init(questID: 249, world: 2, map: 5, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .quest249),
        .init(questID: 256, world: 6, map: 1, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .any),
        .init(questID: 257, world: 1, map: 4, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .quest257),
        .init(questID: 259, world: 5, map: 1, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .quest259),
        .init(questID: 264, world: 4, map: 2, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .quest264),
        .init(questID: 266, world: 2, map: 5, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .quest266),
        .init(questID: 822, world: 2, map: 4, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .any),
        .init(questID: 862, world: 6, map: 3, minimumMap: nil, node: nil, boss: true, rank: .good, fleet: .quest862),
        .init(questID: 875, world: 5, map: 4, minimumMap: nil, node: nil, boss: true, rank: .s, fleet: .quest875)
    ]

    private static let multiMapRules: [MultiMapRule] = [
        // 280
        .init(questID: 280, conditionIndex: 0, world: 1, map: 2, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest280),
        .init(questID: 280, conditionIndex: 1, world: 1, map: 3, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest280),
        .init(questID: 280, conditionIndex: 2, world: 1, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest280),
        .init(questID: 280, conditionIndex: 3, world: 2, map: 1, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest280),
        // 854
        .init(questID: 854, conditionIndex: 0, world: 2, map: 4, node: nil, boss: true, rank: .good, mode: .setOne, fleet: .any),
        .init(questID: 854, conditionIndex: 1, world: 6, map: 1, node: nil, boss: true, rank: .good, mode: .setOne, fleet: .any),
        .init(questID: 854, conditionIndex: 2, world: 6, map: 3, node: nil, boss: true, rank: .good, mode: .setOne, fleet: .any),
        .init(questID: 854, conditionIndex: 3, world: 6, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        // 872
        .init(questID: 872, conditionIndex: 0, world: 7, map: 2, node: 15, boss: false, rank: .s, mode: .setOne, fleet: .any),
        .init(questID: 872, conditionIndex: 1, world: 5, map: 5, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        .init(questID: 872, conditionIndex: 2, world: 6, map: 2, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        .init(questID: 872, conditionIndex: 3, world: 6, map: 5, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        // 873
        .init(questID: 873, conditionIndex: 0, world: 3, map: 1, node: nil, boss: true, rank: .good, mode: .setOne, fleet: .any),
        .init(questID: 873, conditionIndex: 1, world: 3, map: 2, node: nil, boss: true, rank: .good, mode: .setOne, fleet: .any),
        .init(questID: 873, conditionIndex: 2, world: 3, map: 3, node: nil, boss: true, rank: .good, mode: .setOne, fleet: .any),
        // 845
        .init(questID: 845, conditionIndex: 0, world: 4, map: 1, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        .init(questID: 845, conditionIndex: 1, world: 4, map: 2, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        .init(questID: 845, conditionIndex: 2, world: 4, map: 3, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        .init(questID: 845, conditionIndex: 3, world: 4, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        .init(questID: 845, conditionIndex: 4, world: 4, map: 5, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .any),
        // 893 increments each clear
        .init(questID: 893, conditionIndex: 0, world: 1, map: 5, node: nil, boss: true, rank: .s, mode: .increment, fleet: .any),
        .init(questID: 893, conditionIndex: 1, world: 7, map: 1, node: nil, boss: true, rank: .s, mode: .increment, fleet: .any),
        .init(questID: 893, conditionIndex: 2, world: 7, map: 2, node: 7, boss: false, rank: .s, mode: .increment, fleet: .any),
        .init(questID: 893, conditionIndex: 3, world: 7, map: 2, node: 15, boss: false, rank: .s, mode: .increment, fleet: .any),
        // 894
        .init(questID: 894, conditionIndex: 0, world: 1, map: 3, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest894),
        .init(questID: 894, conditionIndex: 1, world: 1, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest894),
        .init(questID: 894, conditionIndex: 2, world: 2, map: 1, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest894),
        .init(questID: 894, conditionIndex: 3, world: 2, map: 2, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest894),
        .init(questID: 894, conditionIndex: 4, world: 2, map: 3, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest894),
        // 284
        .init(questID: 284, conditionIndex: 0, world: 1, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest284),
        .init(questID: 284, conditionIndex: 1, world: 2, map: 1, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest284),
        .init(questID: 284, conditionIndex: 2, world: 2, map: 2, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest284),
        .init(questID: 284, conditionIndex: 3, world: 2, map: 3, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest284),
        // 888
        .init(questID: 888, conditionIndex: 0, world: 5, map: 1, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest888),
        .init(questID: 888, conditionIndex: 1, world: 5, map: 3, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest888),
        .init(questID: 888, conditionIndex: 2, world: 5, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest888),
        // 903
        .init(questID: 903, conditionIndex: 0, world: 5, map: 1, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest903),
        .init(questID: 903, conditionIndex: 1, world: 5, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest903),
        .init(questID: 903, conditionIndex: 2, world: 6, map: 4, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest903),
        .init(questID: 903, conditionIndex: 3, world: 6, map: 5, node: nil, boss: true, rank: .s, mode: .setOne, fleet: .quest903)
    ]

    public init() {}

    public func evaluate(
        _ event: QuestConditionalEvent,
        flags: QuestSessionFlags = QuestSessionFlags()
    ) -> [QuestProgressMutation] {
        switch event {
        case let .nodeReached(node): return evaluateNode(node)
        case let .battleCompleted(battle):
            return battle.battleKind == .practice
                ? evaluatePractice(battle)
                : evaluateSortieBattle(battle, flags: flags)
        }
    }

    private func evaluateNode(_ event: QuestNodeReachedEvent) -> [QuestProgressMutation] {
        var result: [QuestProgressMutation] = []
        if event.isStart { result.append(.increment(questID: 214, conditionIndex: 0, amount: 1)) }
        let bbv = countType(ShipType.bbv, in: event.deck)
        let ao = countType(ShipType.ao, in: event.deck)
        if event.world == 1, event.map == 6, [14, 17].contains(event.node), bbv >= 2 || ao >= 2 {
            result.append(.increment(questID: 861, conditionIndex: 0, amount: 1))
        }
        return result
    }

    private func evaluatePractice(_ event: BattleCompletedQuestEvent) -> [QuestProgressMutation] {
        var result: [QuestProgressMutation] = [.increment(questID: 303, conditionIndex: 0, amount: 1)]
        if RankRequirement.win.accepts(event.rank) {
            for id in [304, 302, 311] {
                result.append(.increment(questID: id, conditionIndex: 0, amount: 1))
            }
            if countType(ShipType.cl, in: event.sortieFleet) == 2 {
                result.append(.increment(questID: 318, conditionIndex: 0, amount: 1))
            }
            let carrierCount = event.sortieFleet.filter { $0.shipType.map(ShipType.carriers.contains) == true }.count
            if event.sortieFleet.first?.shipType.map(ShipType.carriers.contains) == true, carrierCount == 2 {
                result.append(.increment(questID: 330, conditionIndex: 0, amount: 1))
            }
        }
        if RankRequirement.s.accepts(event.rank), countMatches(in: [
            [49, 253, 464, 470], [48, 198, 252], [17, 225, 566], [18, 226, 567]
        ], fleet: event.sortieFleet) == 4 {
            result.append(.increment(questID: 337, conditionIndex: 0, amount: 1))
        }
        if RankRequirement.s.accepts(event.rank), countMatches(in: [
            [12, 206, 666], [368, 486, 647], [13, 195, 207], [14, 208, 627]
        ], fleet: event.sortieFleet) == 4 {
            result.append(.increment(questID: 339, conditionIndex: 0, amount: 1))
        }
        let cl = countType(ShipType.cl, in: event.sortieFleet)
        let destroyers = countTypes([ShipType.dd, ShipType.de], in: event.sortieFleet)
        if RankRequirement.good.accepts(event.rank), cl + destroyers * 10 >= 40 || cl + destroyers * 10 == 31 {
            result.append(.increment(questID: 342, conditionIndex: 0, amount: 1))
        }
        return result
    }

    private func evaluateSortieBattle(
        _ event: BattleCompletedQuestEvent,
        flags: QuestSessionFlags
    ) -> [QuestProgressMutation] {
        var result: [QuestProgressMutation] = [.increment(questID: 210, conditionIndex: 0, amount: 1)]
        if RankRequirement.win.accepts(event.rank) {
            result.append(.increment(questID: 201, conditionIndex: 0, amount: 1))
            result.append(.increment(questID: 216, conditionIndex: 0, amount: 1))
        }

        let sunk = event.enemies.filter { ($0.finalHP ?? 1) <= 0 }
        let carriers = sunk.filter { $0.shipType.map(ShipType.carriers.contains) == true }.count
        let supply = sunk.filter { $0.shipType == ShipType.ap }.count
        let submarines = sunk.filter { $0.shipType.map(ShipType.submarines.contains) == true }.count
        appendCount(carriers, questIDs: [211, 220], to: &result)
        let duplicateMultiplier = flags.apDuplicationEnabled ? 2 : 1
        let duplicatedSupply = min(supply * duplicateMultiplier, 4)
        appendCount(duplicatedSupply, questIDs: [212, 218], to: &result)
        appendCount(supply, questIDs: [213, 221], to: &result)
        appendCount(submarines, questIDs: [230, 228], to: &result)

        if event.isBoss {
            result.append(.increment(questID: 214, conditionIndex: 1, amount: 1))
            if RankRequirement.win.accepts(event.rank) {
                result.append(.increment(questID: 214, conditionIndex: 2, amount: 1))
            }
        }
        if RankRequirement.s.accepts(event.rank) {
            result.append(.increment(questID: 214, conditionIndex: 3, amount: 1))
        }

        for rule in Self.simpleMapRules where matches(rule, event: event) {
            result.append(.increment(questID: rule.questID, conditionIndex: 0, amount: 1))
        }
        for rule in Self.multiMapRules where matches(rule, event: event) {
            switch rule.mode {
            case .setOne:
                result.append(.setAtLeast(questID: rule.questID, conditionIndex: rule.conditionIndex, value: 1))
            case .increment:
                result.append(.increment(questID: rule.questID, conditionIndex: rule.conditionIndex, amount: 1))
            }
        }
        return result
    }

    private func matches(_ rule: MapRule, event: BattleCompletedQuestEvent) -> Bool {
        guard event.world == rule.world,
              rule.map.map({ event.map == $0 }) ?? true,
              rule.minimumMap.map({ (event.map ?? Int.min) >= $0 }) ?? true,
              rule.node.map({ event.node == $0 }) ?? true,
              !rule.boss || event.isBoss,
              rule.rank.accepts(event.rank) else { return false }
        return matches(rule.fleet, fleet: event.sortieFleet)
    }

    private func matches(_ rule: MultiMapRule, event: BattleCompletedQuestEvent) -> Bool {
        guard event.world == rule.world, event.map == rule.map,
              rule.node.map({ event.node == $0 }) ?? true,
              !rule.boss || event.isBoss,
              rule.rank.accepts(event.rank) else { return false }
        return matches(rule.fleet, fleet: event.sortieFleet)
    }

    private func matches(_ predicate: FleetPredicate, fleet: [QuestFleetShip]) -> Bool {
        let ids = fleet.compactMap(\.masterShipID)
        let types = fleet.compactMap(\.shipType)
        let flagshipID = fleet.first?.masterShipID
        let flagshipType = fleet.first?.shipType
        switch predicate {
        case .any:
            return true
        case .quest249:
            return countMatches(
                in: [[62, 265, 319], [63, 192, 266], [65, 194, 268]],
                fleet: fleet
            ) == 3
        case .quest257:
            return flagshipType == ShipType.cl
                && types.allSatisfy { $0 == ShipType.dd || $0 == ShipType.cl }
                && types.filter { $0 == ShipType.cl }.count <= 3
        case .quest259:
            let battleshipIDs: Set<Int> = [
                77,82,87,88,553,554, 26,27,286,287,411,412,
                80,81,275,276,541,573, 131,136,143,148,546,911,916
            ]
            return ids.filter(battleshipIDs.contains).count == 3 && countType(ShipType.cl, in: fleet) == 1
        case .quest264:
            return types.filter(ShipType.carriers.contains).count == 2
                && types.filter { $0 == ShipType.dd }.count == 2
        case .quest266:
            return flagshipType == ShipType.dd
                && types.allSatisfy { [ShipType.dd, ShipType.cl, ShipType.ca].contains($0) }
                && countType(ShipType.ca, in: fleet) == 1
                && countType(ShipType.cl, in: fleet) == 1
                && countType(ShipType.dd, in: fleet) == 4
        case .quest280:
            return countTypes([ShipType.dd, ShipType.de], in: fleet) >= 3
                && countTypes([ShipType.cvl, ShipType.cl], in: fleet) >= 1
        case .quest862:
            return countType(ShipType.cl, in: fleet) >= 2 && countType(ShipType.av, in: fleet) >= 1
        case .quest875:
            return ids.contains(543) && !Set(ids).isDisjoint(with: [344,345,359,569,578,649])
        case .quest894:
            return types.contains(where: ShipType.carriers.contains)
        case .quest284:
            return countTypes([ShipType.cl, ShipType.cvl], in: fleet) == 1
                && countTypes([ShipType.dd, ShipType.de], in: fleet) >= 3
        case .quest888:
            let mikawa: Set<Int> = [51,59,60,61,69,115,123,142,213,262,263,264,272,293,295,416,417,427,477,622,623,624]
            return !Set(ids).isDisjoint(with: mikawa)
        case .quest903:
            let yuubari: Set<Int> = [622,623,624]
            let sixthSquadron: Set<Int> = [1,2,30,31,164,254,255,259,261,308,434,435]
            guard flagshipID.map(yuubari.contains) == true else { return false }
            return ids.contains(488) || ids.filter(sixthSquadron.contains).count >= 2
        }
    }

    private func appendCount(_ amount: Int, questIDs: [Int], to result: inout [QuestProgressMutation]) {
        guard amount > 0 else { return }
        for id in questIDs {
            result.append(.increment(questID: id, conditionIndex: 0, amount: amount))
        }
    }

    private func countMatches(in groups: [[Int]], fleet: [QuestFleetShip]) -> Int {
        let accepted = Set(groups.flatMap { $0 })
        return fleet.compactMap(\.masterShipID).filter(accepted.contains).count
    }

    private func countType(_ type: Int, in fleet: [QuestFleetShip]) -> Int {
        fleet.filter { $0.shipType == type }.count
    }

    private func countTypes(_ types: Set<Int>, in fleet: [QuestFleetShip]) -> Int {
        fleet.filter { $0.shipType.map(types.contains) == true }.count
    }
}
