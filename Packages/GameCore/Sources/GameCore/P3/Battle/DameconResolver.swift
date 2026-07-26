import Foundation

/// Freezes sortie equipment at battle start and resolves one damage-control
/// activation per ship. It never consults the subsequently mutable P2 snapshot.
public enum DameconResolver {
    public static func freezeLoadout(
        in battle: inout BattleSnapshot,
        from fleet: FleetSnapshot
    ) {
        freeze(fleet: &battle.friendlyMain, from: fleet)
        if battle.friendlyEscort != nil {
            freeze(fleet: &battle.friendlyEscort!, from: fleet)
        }
    }

    /// Applies the first lethal hit. Practice battles deliberately neither
    /// consume nor simulate activation.
    public static func resolveLethalDamage(
        ship: inout BattleShipState,
        battleKind: BattleKind,
        phase: BattlePhaseKind
    ) -> DameconActivation? {
        guard ship.currentHP <= 0, battleKind == .sortie,
              var damecon = ship.damecon, !damecon.consumed else {
            return nil
        }

        let restoredHP: Int
        switch damecon.kind {
        case .repairTeam:
            restoredHP = Int(floor(Double(ship.maximumHP) * 0.2))
        case .goddess:
            restoredHP = ship.maximumHP
        }
        ship.currentHP = restoredHP
        damecon.consumed = true
        damecon.triggeredPhase = phase
        ship.damecon = damecon
        return DameconActivation(
            itemInstanceID: damecon.itemInstanceID,
            masterItemID: damecon.kind.rawValue,
            ship: ship.position,
            phase: phase,
            restoredHP: restoredHP
        )
    }

    public static func risk(
        for ship: BattleShipState,
        battleKind: BattleKind
    ) -> BattleRetreatRisk {
        if ship.escaped || battleKind == .practice { return .safe }
        guard ship.maximumHP > 0, ship.currentHP >= 0 else { return .unknown }
        if ship.currentHP == 0 { return .sunk }
        guard ship.currentHP * 4 <= ship.maximumHP else { return .safe }
        if let damecon = ship.damecon, !damecon.consumed {
            return .heavyDamagedWithDamecon
        }
        return .heavyDamaged
    }

    public static func assessments(in battle: BattleSnapshot) -> [BattleShipPosition: BattleRetreatRisk] {
        var result: [BattleShipPosition: BattleRetreatRisk] = [:]
        for ship in battle.friendlyMain.ships {
            result[ship.position] = risk(for: ship, battleKind: battle.kind)
        }
        for ship in battle.friendlyEscort?.ships ?? [] {
            result[ship.position] = risk(for: ship, battleKind: battle.kind)
        }
        return result
    }

    /// Escaped ships are `.safe`, so only ships that can still participate in
    /// the next node produce a warning.
    public static func retreatWarnings(in battle: BattleSnapshot) -> [BattleParseWarning] {
        assessments(in: battle).compactMap { position, risk in
            guard risk != .safe else { return nil }
            return BattleParseWarning(
                field: "retreatRisk",
                message: "\(position.component.rawValue).\(position.index): \(risk.rawValue)"
            )
        }
    }

    private static func freeze(fleet battleFleet: inout BattleFleetState, from snapshot: FleetSnapshot) {
        for index in battleFleet.ships.indices {
            guard case let .friendlyUserShip(shipID) = battleFleet.ships[index].id,
                  let ship = snapshot.ships[shipID],
                  let damecon = firstDamecon(on: ship, items: snapshot.slotItems) else {
                continue
            }
            battleFleet.ships[index].damecon = damecon
        }
    }

    private static func firstDamecon(
        on ship: UserShip,
        items: [Int: UserSlotItem]
    ) -> BattleDameconState? {
        let instanceIDs = ship.slotItemIDs + [ship.extraSlotItemID].compactMap { $0 }
        for instanceID in instanceIDs {
            guard let item = items[instanceID],
                  let kind = BattleDameconKind(rawValue: item.masterSlotItemID) else {
                continue
            }
            return BattleDameconState(itemInstanceID: instanceID, kind: kind)
        }
        return nil
    }
}
