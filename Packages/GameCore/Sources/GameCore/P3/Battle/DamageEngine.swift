import Foundation

public struct DamageApplication: Equatable, Sendable {
    public let applied: Bool
    public let warnings: [BattleParseWarning]
}

public struct DamageEngine: Sendable {
    public init() {}

    @discardableResult
    public func apply(
        _ phase: BattlePhaseResult,
        to snapshot: inout BattleSnapshot,
        eventID: String? = nil,
        appliedEventIDs: inout Set<String>
    ) -> DamageApplication {
        if let eventID, appliedEventIDs.contains(eventID) {
            return DamageApplication(applied: false, warnings: [])
        }
        var warnings = phase.warnings
        for event in phase.events where event.damage > 0 {
            guard mutateShip(
                in: &snapshot,
                friendly: event.targetIsFriendly,
                position: event.target,
                mutation: { ship in
                    ship.currentHP = max(0, ship.currentHP - event.damage)
                }
            ) else {
                warnings.append(.init(
                    field: phase.kind.rawValue,
                    message: "damage target out of range: \(event.target.component.rawValue).\(event.target.index)"
                ))
                continue
            }
        }
        snapshot.phases.append(BattlePhaseResult(
            kind: phase.kind,
            events: phase.events,
            warnings: warnings
        ))
        if let eventID { appliedEventIDs.insert(eventID) }
        return DamageApplication(applied: true, warnings: warnings)
    }

    private func mutateShip(
        in snapshot: inout BattleSnapshot,
        friendly: Bool,
        position: BattleShipPosition,
        mutation: (inout BattleShipState) -> Void
    ) -> Bool {
        switch (friendly, position.component) {
        case (true, .main):
            guard snapshot.friendlyMain.ships.indices.contains(position.index) else { return false }
            mutation(&snapshot.friendlyMain.ships[position.index])
        case (true, .escort):
            guard snapshot.friendlyEscort?.ships.indices.contains(position.index) == true else { return false }
            mutation(&snapshot.friendlyEscort!.ships[position.index])
        case (false, .main):
            guard snapshot.enemyMain.ships.indices.contains(position.index) else { return false }
            mutation(&snapshot.enemyMain.ships[position.index])
        case (false, .escort):
            guard snapshot.enemyEscort?.ships.indices.contains(position.index) == true else { return false }
            mutation(&snapshot.enemyEscort!.ships[position.index])
        }
        return true
    }
}
