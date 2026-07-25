import Foundation

/// Pure fleet calculations ported from Kcanotify's `KcaDeckInfo`.
///
/// The DTOs deliberately do not depend on `FleetSnapshot` so this calculator can be
/// reused by combined-fleet and battle projections without coupling to a reducer.
public enum FleetCalculator {
    public enum Formula33Mode: Sendable, Equatable {
        case coefficient(Int)
        case pureSearch
    }

    public struct Formula33Equipment: Sendable, Equatable {
        public let type: Int
        public let search: Int
        public let improvement: Int

        public init(type: Int, search: Int, improvement: Int = 0) {
            self.type = type
            self.search = search
            self.improvement = improvement
        }
    }

    public struct Formula33Ship: Sendable, Equatable {
        /// One-based fleet position, matching Kcanotify's escape arrays.
        public let position: Int
        /// API `api_sakuteki[0]`; includes equipped item search.
        public let totalSearch: Int
        /// `nil` represents an occupied slot whose item data is unavailable.
        public let equipment: [Formula33Equipment?]
        public let expansionEquipment: Formula33Equipment?

        public init(
            position: Int,
            totalSearch: Int,
            equipment: [Formula33Equipment?] = [],
            expansionEquipment: Formula33Equipment? = nil
        ) {
            self.position = position
            self.totalSearch = totalSearch
            self.equipment = equipment
            self.expansionEquipment = expansionEquipment
        }
    }

    public struct Formula33Result: Sendable, Equatable {
        public let value: Double
        public let pureSearch: Double
        public let shipContribution: Double
        public let equipmentContribution: Double
        public let headquartersPenalty: Double
        public let emptySlotBonus: Double
    }

    /// Formula 33. Coefficients 1, 2, 3 and 4 are supported.
    /// The result follows KcaDeckInfo and is floored (not rounded) to two decimals.
    public static func formula33(
        ships: [Formula33Ship],
        headquartersLevel: Int,
        mode: Formula33Mode,
        excludedPositions: Set<Int> = [],
        fleetCapacity: Int = 6
    ) -> Formula33Result {
        let included = ships.filter { !excludedPositions.contains($0.position) }
        let pure = included.reduce(0.0) { $0 + Double($1.totalSearch) }

        guard case let .coefficient(coefficient) = mode else {
            return Formula33Result(
                value: pure,
                pureSearch: pure,
                shipContribution: 0,
                equipmentContribution: 0,
                headquartersPenalty: 0,
                emptySlotBonus: 0
            )
        }
        precondition((1...4).contains(coefficient), "Formula 33 coefficient must be 1...4")

        var shipContribution = 0.0
        var equipmentContribution = 0.0
        for ship in included {
            let knownEquipment = ship.equipment.compactMap { $0 } + [ship.expansionEquipment].compactMap { $0 }
            let equipmentSearch = knownEquipment.reduce(0) { $0 + $1.search }
            let nakedSearch = max(0, ship.totalSearch - equipmentSearch)
            shipContribution += sqrt(Double(nakedSearch))
            equipmentContribution += knownEquipment.reduce(0.0) { $0 + formula33EquipmentContribution($1) }
        }

        let headquartersPenalty = ceil(0.4 * Double(max(0, headquartersLevel)))
        // An escaped position is skipped before KcaDeckInfo decrements noShipCount,
        // therefore it intentionally receives the same +2 correction as an empty slot.
        let emptyCount = max(0, fleetCapacity - included.count)
        let emptySlotBonus = Double(2 * emptyCount)
        let unrounded = shipContribution
            + Double(coefficient) * equipmentContribution
            - headquartersPenalty
            + emptySlotBonus
        let value = floor(unrounded * 100) / 100

        return Formula33Result(
            value: value,
            pureSearch: pure,
            shipContribution: shipContribution,
            equipmentContribution: equipmentContribution,
            headquartersPenalty: headquartersPenalty,
            emptySlotBonus: emptySlotBonus
        )
    }

    /// Equipment term from KcaDeckInfo.getEquipSeek(type, search, improvement).
    public static func formula33EquipmentContribution(_ item: Formula33Equipment) -> Double {
        let search = Double(item.search)
        let rootImprovement = sqrt(Double(max(0, item.improvement)))
        switch item.type {
        case 8: // torpedo bomber
            return 0.8 * search
        case 9, 94: // carrier reconnaissance
            return search + 1.2 * rootImprovement
        case 10: // seaplane reconnaissance
            return 1.2 * (search + 1.2 * rootImprovement)
        case 11: // seaplane bomber
            return 1.1 * (search + 1.15 * rootImprovement)
        case 13: // large radar
            return 0.6 * (search + 1.4 * rootImprovement)
        case 12: // small radar
            return 0.6 * (search + 1.25 * rootImprovement)
        case 41: // flying boat
            return 0.6 * (search + 1.2 * rootImprovement)
        default:
            return 0.6 * search
        }
    }

    public struct AircraftSlot: Sendable, Equatable {
        public let position: Int
        public let itemID: Int
        public let type: Int
        public let antiAir: Int
        public let aircraftCount: Int
        public let improvement: Int
        /// API `api_alv`, clamped to 0...7.
        public let proficiency: Int
        /// Expansion slots are excluded, matching KcaDeckInfo.getAirPowerRange.
        public let isExpansionSlot: Bool

        public init(
            position: Int,
            itemID: Int,
            type: Int,
            antiAir: Int,
            aircraftCount: Int,
            improvement: Int = 0,
            proficiency: Int = 0,
            isExpansionSlot: Bool = false
        ) {
            self.position = position
            self.itemID = itemID
            self.type = type
            self.antiAir = antiAir
            self.aircraftCount = aircraftCount
            self.improvement = improvement
            self.proficiency = proficiency
            self.isExpansionSlot = isExpansionSlot
        }
    }

    public struct AirPowerRange: Sendable, Equatable {
        public let minimum: Int
        public let maximum: Int

        public init(minimum: Int, maximum: Int) {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    public static func airPowerRange(
        slots: [AircraftSlot],
        excludedPositions: Set<Int> = []
    ) -> AirPowerRange {
        var minimum = 0
        var maximum = 0
        for slot in slots where !excludedPositions.contains(slot.position) && !slot.isExpansionSlot {
            guard slot.aircraftCount > 0, fighterAircraftTypes.contains(slot.type) else { continue }
            let reinforced = reinforcedAntiAir(for: slot)
            let base = sqrt(Double(slot.aircraftCount)) * reinforced
            let mastery = masteryRange(type: slot.type, proficiency: slot.proficiency)
            minimum += Int(floor(base + mastery.minimum))
            maximum += Int(floor(base + mastery.maximum))
        }
        return AirPowerRange(minimum: minimum, maximum: maximum)
    }

    public enum MoraleState: String, Sendable, Codable, Equatable {
        case sparkling
        case normal
        case lightFatigue
        case orangeFatigue
        case redFatigue
    }

    public struct MoraleShip: Sendable, Equatable {
        public let position: Int
        public let condition: Int

        public init(position: Int, condition: Int) {
            self.position = position
            self.condition = condition
        }
    }

    public struct MoraleStatus: Sendable, Equatable {
        public let position: Int
        public let condition: Int
        public let state: MoraleState
        public let isBelowThreshold: Bool
    }

    public struct FleetMorale: Sendable, Equatable {
        public let ships: [MoraleStatus]
        /// Matches KcaDeckInfo.checkMinimumMorale: an empty fleet returns 100.
        public let minimumCondition: Int
        public let threshold: Int
        public var isReady: Bool { minimumCondition >= threshold }
    }

    public static func morale(
        ships: [MoraleShip],
        threshold: Int = 40,
        excludedPositions: Set<Int> = []
    ) -> FleetMorale {
        let effectiveThreshold = max(0, threshold)
        let statuses = ships
            .filter { !excludedPositions.contains($0.position) }
            .map { ship in
                MoraleStatus(
                    position: ship.position,
                    condition: ship.condition,
                    state: moraleState(for: ship.condition),
                    isBelowThreshold: ship.condition < effectiveThreshold
                )
            }
        return FleetMorale(
            ships: statuses,
            minimumCondition: statuses.map(\.condition).min() ?? 100,
            threshold: effectiveThreshold
        )
    }

    public static func moraleState(for condition: Int) -> MoraleState {
        switch condition {
        case 50...: return .sparkling
        case 40...49: return .normal
        case 30...39: return .lightFatigue
        case 20...29: return .orangeFatigue
        default: return .redFatigue
        }
    }

    private static let fighterAircraftTypes: Set<Int> = [6, 7, 8, 11, 45, 47, 48, 56, 57, 58]
    private static let basicMasteryMinimum = [0, 10, 25, 40, 55, 70, 85, 100]
    private static let basicMasteryMaximum = [9, 24, 39, 54, 69, 84, 99, 120]
    private static let fighterMasteryBonus = [0, 0, 2, 5, 9, 14, 14, 22]
    private static let seaBomberMasteryBonus = [0, 0, 1, 1, 1, 3, 3, 6]

    private static func reinforcedAntiAir(for slot: AircraftSlot) -> Double {
        let improvement = Double(max(0, slot.improvement))
        let bonus: Double
        if [60, 154, 219, 447].contains(slot.itemID) {
            bonus = 0.25 * improvement
        } else if [486, 487].contains(slot.itemID) {
            bonus = 0.3 * improvement
        } else if [6, 45, 48].contains(slot.type) {
            bonus = 0.2 * improvement
        } else if [47, 53].contains(slot.type) {
            bonus = 0.5 * sqrt(improvement)
        } else {
            bonus = 0
        }
        return slot.antiAir > 0 ? Double(slot.antiAir) + bonus : Double(slot.antiAir)
    }

    private static func masteryRange(type: Int, proficiency: Int) -> (minimum: Double, maximum: Double) {
        let level = min(7, max(0, proficiency))
        let basicMinimum = sqrt(Double(basicMasteryMinimum[level]) / 10)
        let basicMaximum = sqrt(Double(basicMasteryMaximum[level]) / 10)
        switch type {
        case 6, 45, 48:
            return (
                Double(fighterMasteryBonus[level]) + basicMinimum,
                Double(fighterMasteryBonus[level]) + basicMaximum
            )
        case 7, 8, 57, 47:
            return (basicMinimum, basicMaximum)
        case 11:
            return (
                Double(seaBomberMasteryBonus[level]) + basicMinimum,
                Double(seaBomberMasteryBonus[level]) + basicMaximum
            )
        default:
            return (0, 0)
        }
    }
}
