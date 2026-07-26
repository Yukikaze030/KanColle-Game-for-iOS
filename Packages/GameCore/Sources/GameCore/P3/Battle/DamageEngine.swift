import Foundation

/// Converts the server's target number into one of the four battle fleet arrays.
///
/// Shelling target numbers use a global 0...11 space, while vector phases may
/// provide an escort-only local 0...5 array. Keeping both representations here
/// prevents phase decoders from growing scattered `6`/`12` offset arithmetic.
public struct BattleTargetLayout: Equatable, Sendable {
    public enum IndexSpace: Equatable, Sendable {
        /// Global shelling indices 0...5.
        case main
        /// Global shelling indices 6...11.
        case escort
        /// Local vector indices 0...5 that all address the escort.
        case escortLocal
        /// Global shelling indices 0...11.
        case combined
    }

    public let friendly: IndexSpace
    public let enemy: IndexSpace

    public init(friendly: IndexSpace, enemy: IndexSpace) {
        self.friendly = friendly
        self.enemy = enemy
    }

    public func resolve(rawIndex: Int, targetIsFriendly: Bool) -> BattleShipPosition? {
        Self.resolve(rawIndex: rawIndex, in: targetIsFriendly ? friendly : enemy)
    }

    private static let fleetCapacity = 6

    private static func resolve(rawIndex: Int, in indexSpace: IndexSpace) -> BattleShipPosition? {
        guard rawIndex >= 0 else { return nil }
        switch indexSpace {
        case .main:
            guard rawIndex < fleetCapacity else { return nil }
            return .init(component: .main, index: rawIndex)
        case .escort:
            guard rawIndex >= fleetCapacity, rawIndex < fleetCapacity * 2 else { return nil }
            return .init(component: .escort, index: rawIndex - fleetCapacity)
        case .escortLocal:
            guard rawIndex < fleetCapacity else { return nil }
            return .init(component: .escort, index: rawIndex)
        case .combined:
            guard rawIndex < fleetCapacity * 2 else { return nil }
            if rawIndex < fleetCapacity {
                return .init(component: .main, index: rawIndex)
            }
            return .init(component: .escort, index: rawIndex - fleetCapacity)
        }
    }

}

public struct DamageApplication: Equatable, Sendable {
    public let applied: Bool
    public let warnings: [BattleParseWarning]
}

public struct DamageEngine: Sendable {
    private struct ShipMutation {
        let activation: DameconActivation?
    }

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
        let battleKind = snapshot.kind
        var warnings = phase.warnings
        for event in phase.events where event.damage > 0 {
            guard let mutation = mutateShip(
                in: &snapshot,
                friendly: event.targetIsFriendly,
                position: event.target,
                mutation: { ship -> DameconActivation? in
                    ship.currentHP = max(0, ship.currentHP - event.damage)
                    guard event.targetIsFriendly else { return nil }
                    return DameconResolver.resolveLethalDamage(
                        ship: &ship,
                        battleKind: battleKind,
                        phase: phase.kind
                    )
                }
            ) else {
                warnings.append(.init(
                    field: phase.kind.rawValue,
                    message: "damage target out of range: \(event.target.component.rawValue).\(event.target.index)"
                ))
                continue
            }
            if let activation = mutation.activation {
                snapshot.dameconActivations.append(activation)
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
        mutation: (inout BattleShipState) -> DameconActivation?
    ) -> ShipMutation? {
        switch (friendly, position.component) {
        case (true, .main):
            guard snapshot.friendlyMain.ships.indices.contains(position.index) else { return nil }
            return ShipMutation(activation: mutation(&snapshot.friendlyMain.ships[position.index]))
        case (true, .escort):
            guard snapshot.friendlyEscort?.ships.indices.contains(position.index) == true else { return nil }
            return ShipMutation(activation: mutation(&snapshot.friendlyEscort!.ships[position.index]))
        case (false, .main):
            guard snapshot.enemyMain.ships.indices.contains(position.index) else { return nil }
            return ShipMutation(activation: mutation(&snapshot.enemyMain.ships[position.index]))
        case (false, .escort):
            guard snapshot.enemyEscort?.ships.indices.contains(position.index) == true else { return nil }
            return ShipMutation(activation: mutation(&snapshot.enemyEscort!.ships[position.index]))
        }
    }
}
