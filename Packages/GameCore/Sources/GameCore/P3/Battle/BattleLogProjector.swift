import Foundation

public struct BattlePhaseSummary: Codable, Equatable, Sendable {
    public let kind: BattlePhaseKind
    public let friendlyDamage: Int
    public let enemyDamage: Int
    public let friendlySunk: Int
    public let enemySunk: Int
    public let warnings: [String]
}

public struct BattleLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let startedAt: Date
    public let map: BattleMapPosition?
    public let kind: BattleKind
    public let enemyFleetName: String?
    public let predictedRank: BattleRank?
    public let actualRank: BattleRank?
    public let friendlyFinalHP: [Int]
    public let enemyFinalHP: [Int]
    public let escapedPositions: [BattleShipPosition]
    public let dameconSummary: String?
    public let phases: [BattlePhaseSummary]
}

public struct BattleLogProjector: Sendable {
    public static let maximumEntries = 100
    public static let maximumPhases = 32

    public init() {}

    public func project(
        snapshot: BattleSnapshot,
        startedAt: Date,
        enemyFleetName: String? = nil,
        prediction: BattleRankPrediction? = nil,
        serverResult: BattleServerResult? = nil,
        dameconSummary: String? = nil
    ) -> BattleLogEntry {
        var friendlyHP = initialHP(snapshot.friendlyMain, snapshot.friendlyEscort)
        var enemyHP = initialHP(snapshot.enemyMain, snapshot.enemyEscort)
        var summaries: [BattlePhaseSummary] = []

        for phase in snapshot.phases.prefix(Self.maximumPhases) {
            var friendlyDamage = 0
            var enemyDamage = 0
            var friendlySunk = 0
            var enemySunk = 0
            for event in phase.events {
                let offset = event.target.component == .main ? 0 : 6
                let index = offset + event.target.index
                if event.targetIsFriendly {
                    friendlyDamage += event.damage
                    if apply(event.damage, at: index, to: &friendlyHP) { friendlySunk += 1 }
                } else {
                    enemyDamage += event.damage
                    if apply(event.damage, at: index, to: &enemyHP) { enemySunk += 1 }
                }
            }
            summaries.append(.init(
                kind: phase.kind,
                friendlyDamage: friendlyDamage,
                enemyDamage: enemyDamage,
                friendlySunk: friendlySunk,
                enemySunk: enemySunk,
                warnings: phase.warnings.prefix(8).map {
                    truncate("\($0.field): \($0.message)", limit: 128)
                }
            ))
        }

        return .init(
            sessionID: snapshot.sessionID,
            startedAt: startedAt,
            map: snapshot.map,
            kind: snapshot.kind,
            enemyFleetName: enemyFleetName.map { truncate($0, limit: 128) },
            predictedRank: prediction?.rank,
            actualRank: serverResult?.rank,
            friendlyFinalHP: finalHP(snapshot.friendlyMain, snapshot.friendlyEscort),
            enemyFinalHP: finalHP(snapshot.enemyMain, snapshot.enemyEscort),
            escapedPositions: escaped(snapshot.friendlyMain, snapshot.friendlyEscort),
            dameconSummary: dameconSummary.map { truncate($0, limit: 512) },
            phases: summaries
        )
    }

    public func inserting(
        _ entry: BattleLogEntry,
        into entries: [BattleLogEntry]
    ) -> [BattleLogEntry] {
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.sessionID, $0) })
        byID[entry.sessionID] = entry
        return byID.values
            .sorted {
                if $0.startedAt == $1.startedAt {
                    return $0.sessionID.uuidString < $1.sessionID.uuidString
                }
                return $0.startedAt > $1.startedAt
            }
            .prefix(Self.maximumEntries)
            .map { $0 }
    }

    private func initialHP(_ main: BattleFleetState, _ escort: BattleFleetState?) -> [Int] {
        padded(main.ships.map(\.initialHP)) + padded(escort?.ships.map(\.initialHP) ?? [])
    }

    private func finalHP(_ main: BattleFleetState, _ escort: BattleFleetState?) -> [Int] {
        main.ships.map(\.currentHP) + (escort?.ships.map(\.currentHP) ?? [])
    }

    private func escaped(_ main: BattleFleetState, _ escort: BattleFleetState?) -> [BattleShipPosition] {
        (main.ships + (escort?.ships ?? [])).filter(\.escaped).map(\.position)
    }

    /// Battle protocol target offsets reserve six slots for the main fleet.
    private func padded(_ values: [Int]) -> [Int] {
        values + Array(repeating: 0, count: max(0, 6 - values.count))
    }

    private func apply(_ damage: Int, at index: Int, to hp: inout [Int]) -> Bool {
        guard hp.indices.contains(index), hp[index] > 0 else { return false }
        let wasAlive = hp[index] > 0
        hp[index] = max(0, hp[index] - max(0, damage))
        return wasAlive && hp[index] == 0
    }

    private func truncate(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }
}
