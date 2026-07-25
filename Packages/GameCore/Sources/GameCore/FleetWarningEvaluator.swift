import Foundation

/// Immutable input for sortie-safety checks. It deliberately stays independent
/// from the mutable API snapshot so the rules can be reused by UI and widgets.
public struct FleetWarningShip: Sendable, Equatable {
    public let id: Int
    public let masterShipID: Int
    public let level: Int
    public let currentHP: Int
    public let maximumHP: Int
    public let isLocked: Bool
    public let fuel: Int?
    public let ammunition: Int?
    public let slotItemIDs: [Int]
    public let extraSlotItemID: Int?

    public init(
        id: Int, masterShipID: Int, level: Int, currentHP: Int, maximumHP: Int,
        isLocked: Bool = false, fuel: Int? = nil, ammunition: Int? = nil,
        slotItemIDs: [Int] = [], extraSlotItemID: Int? = nil
    ) {
        self.id = id
        self.masterShipID = masterShipID
        self.level = level
        self.currentHP = currentHP
        self.maximumHP = maximumHP
        self.isLocked = isLocked
        self.fuel = fuel
        self.ammunition = ammunition
        self.slotItemIDs = slotItemIDs
        self.extraSlotItemID = extraSlotItemID
    }
}

public struct FleetWarningItem: Sendable, Equatable {
    public let id: Int
    public let category: Int
    public let isLocked: Bool

    public init(id: Int, category: Int, isLocked: Bool = false) {
        self.id = id
        self.category = category
        self.isLocked = isLocked
    }
}

public struct FleetWarningMasterShip: Sendable, Equatable {
    public let id: Int
    public let fuelMaximum: Int?
    public let ammunitionMaximum: Int?

    public init(id: Int, fuelMaximum: Int?, ammunitionMaximum: Int?) {
        self.id = id
        self.fuelMaximum = fuelMaximum
        self.ammunitionMaximum = ammunitionMaximum
    }
}

public struct FleetWarningConfiguration: Sendable, Equatable {
    public var onlyLockedShipsOrEquipment: Bool
    public var minimumLevel: Int

    public init(onlyLockedShipsOrEquipment: Bool = false, minimumLevel: Int = 0) {
        self.onlyLockedShipsOrEquipment = onlyLockedShipsOrEquipment
        self.minimumLevel = max(0, minimumLevel)
    }
}

public enum HeavyDamageWarning: String, Sendable, Equatable {
    case none
    case heavyWithDamecon
    case heavyWithoutDamecon
}

public enum SupplyWarning: String, Sendable, Equatable {
    case supplied
    case notSupplied
    case unknown
}

public struct FleetShipWarning: Sendable, Equatable {
    public let shipID: Int
    public let heavyDamage: HeavyDamageWarning
    public let supply: SupplyWarning
    public let isInRepairDock: Bool
    public let wasFiltered: Bool
}

public struct AkashiRepairProjection: Sendable, Equatable {
    public let flagshipID: Int
    public let repairablePositionCount: Int
}

public struct FleetWarningResult: Sendable, Equatable {
    public let ships: [FleetShipWarning]
    public let akashiRepair: AkashiRepairProjection?

    public var hasUnsafeHeavyDamage: Bool {
        ships.contains { $0.heavyDamage == .heavyWithoutDamecon }
    }
    public var hasAnyHeavyDamage: Bool {
        ships.contains { $0.heavyDamage != .none }
    }
    public var hasUnsuppliedShip: Bool {
        ships.contains { $0.supply == .notSupplied }
    }
}

public enum FleetWarningEvaluator {
    /// Kcanotify constants: T2_DAMECON=23, T2_REPAIR_INFRA=31.
    public static let dameconCategory = 23
    public static let repairFacilityCategory = 31
    public static let akashiMasterShipIDs: Set<Int> = [182, 187, 985]

    public static func evaluate(
        ships: [FleetWarningShip],
        items: [Int: FleetWarningItem],
        masterShips: [Int: FleetWarningMasterShip],
        repairingShipIDs: Set<Int> = [],
        configuration: FleetWarningConfiguration = .init()
    ) -> FleetWarningResult {
        let warnings = ships.map { ship in
            let equippedItems = ship.slotItemIDs.compactMap { items[$0] }
                + [ship.extraSlotItemID].compactMap { $0 }.compactMap { items[$0] }
            let hasLockedEquipment = equippedItems.contains(where: \.isLocked)
            let filtered = ship.level < configuration.minimumLevel
                || (configuration.onlyLockedShipsOrEquipment && !ship.isLocked && !hasLockedEquipment)
            let isRepairing = repairingShipIDs.contains(ship.id)

            let heavyDamage: HeavyDamageWarning
            if filtered || isRepairing || ship.maximumHP <= 0 || ship.currentHP * 4 > ship.maximumHP {
                heavyDamage = .none
            } else if equippedItems.contains(where: { $0.category == dameconCategory }) {
                heavyDamage = .heavyWithDamecon
            } else {
                heavyDamage = .heavyWithoutDamecon
            }

            return FleetShipWarning(
                shipID: ship.id,
                heavyDamage: heavyDamage,
                supply: supplyState(ship: ship, master: masterShips[ship.masterShipID]),
                isInRepairDock: isRepairing,
                wasFiltered: filtered
            )
        }
        return FleetWarningResult(ships: warnings, akashiRepair: akashiProjection(ships: ships, items: items))
    }

    private static func supplyState(
        ship: FleetWarningShip,
        master: FleetWarningMasterShip?
    ) -> SupplyWarning {
        guard let fuel = ship.fuel, let ammunition = ship.ammunition,
              let fuelMaximum = master?.fuelMaximum,
              let ammunitionMaximum = master?.ammunitionMaximum else {
            return .unknown
        }
        return fuel == fuelMaximum && ammunition == ammunitionMaximum ? .supplied : .notSupplied
    }

    private static func akashiProjection(
        ships: [FleetWarningShip],
        items: [Int: FleetWarningItem]
    ) -> AkashiRepairProjection? {
        guard let flagship = ships.first, akashiMasterShipIDs.contains(flagship.masterShipID) else {
            return nil
        }
        let facilities = flagship.slotItemIDs.compactMap { items[$0] }
            .filter { $0.category == repairFacilityCategory }.count
        let baseCount = flagship.masterShipID == 985 ? 1 : 2
        return AkashiRepairProjection(
            flagshipID: flagship.id,
            repairablePositionCount: min(ships.count, baseCount + facilities)
        )
    }
}
