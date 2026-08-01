import Foundation

public struct AdmiralSnapshot: Codable, Sendable, Equatable {
    public let memberID: Int?
    public let nickname: String
    public let level: Int?
    public let experience: Int?
}

public struct UserShip: Codable, Sendable, Equatable {
    public let id: Int
    public let masterShipID: Int
    public let level: Int
    public let currentHP: Int
    public let maximumHP: Int
    public let condition: Int
    /// API `api_sakuteki[0]`, including equipment search.
    /// Optional so snapshots persisted by earlier app versions remain decodable.
    public let search: Int?
    public let fuel: Int
    public let ammunition: Int
    public let slotItemIDs: [Int]
    public let aircraftCounts: [Int]
    public let extraSlotItemID: Int?
    public let locked: Bool

    public init(
        id: Int,
        masterShipID: Int,
        level: Int,
        currentHP: Int,
        maximumHP: Int,
        condition: Int,
        search: Int? = nil,
        fuel: Int = 0,
        ammunition: Int = 0,
        slotItemIDs: [Int],
        aircraftCounts: [Int],
        extraSlotItemID: Int?,
        locked: Bool
    ) {
        self.id = id
        self.masterShipID = masterShipID
        self.level = level
        self.currentHP = currentHP
        self.maximumHP = maximumHP
        self.condition = condition
        self.search = search
        self.fuel = fuel
        self.ammunition = ammunition
        self.slotItemIDs = slotItemIDs
        self.aircraftCounts = aircraftCounts
        self.extraSlotItemID = extraSlotItemID
        self.locked = locked
    }

    /// Kcanotify uses `nowhp * 4 <= maxhp` for the basic taiha determination.
    public var isHeavilyDamaged: Bool {
        maximumHP > 0 && currentHP * 4 <= maximumHP
    }
}

public struct UserSlotItem: Codable, Sendable, Equatable {
    public let id: Int
    public let masterSlotItemID: Int
    public let improvementLevel: Int
    public let aircraftProficiency: Int
    public let locked: Bool
}

public struct ExpeditionState: Codable, Sendable, Equatable {
    public let status: Int
    public let missionID: Int
    public let completionTime: Int64?

    public var isActive: Bool { status > 0 && missionID > 0 }
}

public struct FleetDeck: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let shipIDs: [Int]
    public let expedition: ExpeditionState?
}

public struct RepairDock: Codable, Sendable, Equatable {
    public let id: Int
    public let state: Int
    public let shipID: Int?
    public let completionTime: Int64?

    public var isOccupied: Bool { state > 0 && (shipID ?? 0) > 0 }
}

public struct FleetSnapshot: Codable, Sendable, Equatable {
    public internal(set) var admiral: AdmiralSnapshot?
    public internal(set) var ships: [Int: UserShip]
    public internal(set) var slotItems: [Int: UserSlotItem]
    public internal(set) var decks: [Int: FleetDeck]
    public internal(set) var repairDocks: [Int: RepairDock]
    public internal(set) var combinedFleetType: Int

    public init(
        admiral: AdmiralSnapshot? = nil,
        ships: [Int: UserShip] = [:],
        slotItems: [Int: UserSlotItem] = [:],
        decks: [Int: FleetDeck] = [:],
        repairDocks: [Int: RepairDock] = [:],
        combinedFleetType: Int = 0
    ) {
        self.admiral = admiral
        self.ships = ships
        self.slotItems = slotItems
        self.decks = decks
        self.repairDocks = repairDocks
        self.combinedFleetType = combinedFleetType
    }

    public func ships(inDeck deckID: Int) -> [UserShip] {
        guard let deck = decks[deckID] else { return [] }
        return deck.shipIDs.compactMap { ships[$0] }
    }

    public func heavilyDamagedShipIDs(inDeck deckID: Int) -> [Int] {
        ships(inDeck: deckID).filter(\.isHeavilyDamaged).map(\.id)
    }

    public func containsHeavyDamage(inDeck deckID: Int) -> Bool {
        !heavilyDamagedShipIDs(inDeck: deckID).isEmpty
    }

    mutating func replaceShips(from values: [JSONValue]) {
        var replacement: [Int: UserShip] = [:]
        for value in values {
            if let ship = Self.parseShip(value, previous: nil) { replacement[ship.id] = ship }
        }
        ships = replacement
    }

    mutating func mergeShips(from values: [JSONValue]) {
        for value in values {
            guard let id = value.objectValue?.int("api_id"),
                  let ship = Self.parseShip(value, previous: ships[id]) else { continue }
            ships[id] = ship
        }
    }

    mutating func replaceSlotItems(from values: [JSONValue]) {
        var replacement: [Int: UserSlotItem] = [:]
        for value in values {
            if let item = Self.parseSlotItem(value, previous: nil) { replacement[item.id] = item }
        }
        slotItems = replacement
    }

    mutating func mergeSlotItems(from values: [JSONValue]) {
        for value in values {
            guard let id = value.objectValue?.int("api_id"),
                  let item = Self.parseSlotItem(value, previous: slotItems[id]) else { continue }
            slotItems[id] = item
        }
    }

    mutating func replaceDecks(from values: [JSONValue]) {
        var replacement: [Int: FleetDeck] = [:]
        for value in values {
            if let deck = Self.parseDeck(value, previous: nil) { replacement[deck.id] = deck }
        }
        decks = replacement
    }

    mutating func mergeDecks(from values: [JSONValue]) {
        for value in values {
            guard let id = value.objectValue?.int("api_id"),
                  let deck = Self.parseDeck(value, previous: decks[id]) else { continue }
            decks[id] = deck
        }
    }

    mutating func replaceRepairDocks(from values: [JSONValue]) {
        repairDocks = Dictionary(uniqueKeysWithValues: values.compactMap(Self.parseRepairDock).map { ($0.id, $0) })
    }

    @discardableResult
    mutating func replaceDeck(_ deck: FleetDeck) -> Bool {
        let changed = decks[deck.id] != deck
        decks[deck.id] = deck
        return changed
    }

    @discardableResult
    mutating func updateShip(
        id: Int,
        currentHP: Int? = nil,
        condition: Int? = nil,
        fuel: Int? = nil,
        ammunition: Int? = nil,
        aircraftCounts: [Int]? = nil
    ) -> Bool {
        guard let previous = ships[id] else { return false }
        let updated = UserShip(
            id: previous.id,
            masterShipID: previous.masterShipID,
            level: previous.level,
            currentHP: currentHP ?? previous.currentHP,
            maximumHP: previous.maximumHP,
            condition: condition ?? previous.condition,
            search: previous.search,
            fuel: fuel ?? previous.fuel,
            ammunition: ammunition ?? previous.ammunition,
            slotItemIDs: previous.slotItemIDs,
            aircraftCounts: aircraftCounts ?? previous.aircraftCounts,
            extraSlotItemID: previous.extraSlotItemID,
            locked: previous.locked
        )
        guard updated != previous else { return false }
        ships[id] = updated
        return true
    }

    @discardableResult
    mutating func setDeckShipIDs(deckID: Int, shipIDs: [Int]) -> Bool {
        guard let previous = decks[deckID] else { return false }
        let updated = FleetDeck(
            id: previous.id,
            name: previous.name,
            shipIDs: shipIDs.filter { $0 > 0 },
            expedition: previous.expedition
        )
        return replaceDeck(updated)
    }

    @discardableResult
    mutating func setDeckExpedition(deckID: Int, expedition: ExpeditionState?) -> Bool {
        guard let previous = decks[deckID] else { return false }
        return replaceDeck(FleetDeck(
            id: previous.id,
            name: previous.name,
            shipIDs: previous.shipIDs,
            expedition: expedition
        ))
    }

    @discardableResult
    mutating func setRepairDock(_ dock: RepairDock) -> Bool {
        let changed = repairDocks[dock.id] != dock
        repairDocks[dock.id] = dock
        return changed
    }

    mutating func updateAdmiral(from value: JSONValue) {
        guard let object = value.objectValue else { return }
        admiral = AdmiralSnapshot(
            memberID: object.int("api_member_id"),
            nickname: object.string("api_nickname") ?? "",
            level: object.int("api_level"),
            experience: object.int("api_experience")
        )
    }

    private static func parseShip(_ value: JSONValue, previous: UserShip?) -> UserShip? {
        guard let object = value.objectValue, let id = object.int("api_id") else { return nil }
        return UserShip(
            id: id,
            masterShipID: object.int("api_ship_id") ?? previous?.masterShipID ?? 0,
            level: object.int("api_lv") ?? previous?.level ?? 0,
            currentHP: object.int("api_nowhp") ?? previous?.currentHP ?? 0,
            maximumHP: object.int("api_maxhp") ?? previous?.maximumHP ?? 0,
            condition: object.int("api_cond") ?? previous?.condition ?? 0,
            search: object["api_sakuteki"]?.arrayValue?.first?.intValue ?? previous?.search,
            fuel: object.int("api_fuel") ?? previous?.fuel ?? 0,
            ammunition: object.int("api_bull") ?? previous?.ammunition ?? 0,
            slotItemIDs: object["api_slot"] == nil ? (previous?.slotItemIDs ?? []) : object.intArray("api_slot").filter { $0 > 0 },
            aircraftCounts: object["api_onslot"] == nil ? (previous?.aircraftCounts ?? []) : object.intArray("api_onslot"),
            extraSlotItemID: normalizedPositive(object.int("api_slot_ex")) ?? previous?.extraSlotItemID,
            locked: object.int("api_locked").map { $0 != 0 } ?? previous?.locked ?? false
        )
    }

    private static func parseSlotItem(_ value: JSONValue, previous: UserSlotItem?) -> UserSlotItem? {
        guard let object = value.objectValue, let id = object.int("api_id") else { return nil }
        return UserSlotItem(
            id: id,
            masterSlotItemID: object.int("api_slotitem_id") ?? previous?.masterSlotItemID ?? 0,
            improvementLevel: object.int("api_level") ?? previous?.improvementLevel ?? 0,
            aircraftProficiency: object.int("api_alv") ?? previous?.aircraftProficiency ?? 0,
            locked: object.int("api_locked").map { $0 != 0 } ?? previous?.locked ?? false
        )
    }

    private static func parseDeck(_ value: JSONValue, previous: FleetDeck?) -> FleetDeck? {
        guard let object = value.objectValue, let id = object.int("api_id") else { return nil }
        let shipIDs = object["api_ship"] == nil
            ? (previous?.shipIDs ?? [])
            : object.intArray("api_ship").filter { $0 > 0 }
        let expedition: ExpeditionState?
        if let mission = object["api_mission"]?.arrayValue {
            let values = mission.compactMap(\.int64Value)
            if values.count >= 2 {
                expedition = ExpeditionState(
                    status: Int(exactly: values[0]) ?? 0,
                    missionID: Int(exactly: values[1]) ?? 0,
                    completionTime: values.count > 2 && values[2] > 0 ? values[2] : nil
                )
            } else {
                expedition = nil
            }
        } else {
            expedition = previous?.expedition
        }
        return FleetDeck(
            id: id,
            name: object.string("api_name") ?? previous?.name ?? "",
            shipIDs: shipIDs,
            expedition: expedition
        )
    }

    private static func parseRepairDock(_ value: JSONValue) -> RepairDock? {
        guard let object = value.objectValue, let id = object.int("api_id") else { return nil }
        return RepairDock(
            id: id,
            state: object.int("api_state") ?? 0,
            shipID: normalizedPositive(object.int("api_ship_id")),
            completionTime: object.int64("api_complete_time").flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func normalizedPositive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
