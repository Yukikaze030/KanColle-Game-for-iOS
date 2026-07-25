import Foundation

public struct MasterShip: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let shipTypeID: Int
    public let nextShipID: Int?
    public let speed: Int?
    public let slotCount: Int?
    public let fuelMaximum: Int?
    public let ammunitionMaximum: Int?
}

public struct MasterSlotItem: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let type: [Int]
    public let antiSubmarine: Int?

    public var category: Int? { type.count > 2 ? type[2] : nil }
}

public struct MasterShipType: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let equipmentTypes: [Int: Int]
}

public struct MasterMapArea: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let type: Int?
}

public struct MasterMap: Codable, Sendable, Equatable {
    public let id: Int
    public let mapAreaID: Int
    public let number: Int
    public let name: String
}

/// The subset of api_start2 master data required by the initial fleet pipeline.
/// Applying a new start2 payload replaces each collection present in that payload.
public struct GameMasterData: Codable, Sendable, Equatable {
    public private(set) var ships: [Int: MasterShip] = [:]
    public private(set) var slotItems: [Int: MasterSlotItem] = [:]
    public private(set) var shipTypes: [Int: MasterShipType] = [:]
    public private(set) var mapAreas: [Int: MasterMapArea] = [:]
    public private(set) var maps: [Int: MasterMap] = [:]

    public init() {}

    @discardableResult
    public mutating func applyStart2(_ data: JSONValue) -> Bool {
        guard let object = data.objectValue else { return false }
        var changed = false

        if let values = object["api_mst_ship"]?.arrayValue {
            ships = Dictionary(uniqueKeysWithValues: values.compactMap(Self.parseShip).map { ($0.id, $0) })
            changed = true
        }
        if let values = object["api_mst_slotitem"]?.arrayValue {
            slotItems = Dictionary(uniqueKeysWithValues: values.compactMap(Self.parseSlotItem).map { ($0.id, $0) })
            changed = true
        }
        if let values = object["api_mst_stype"]?.arrayValue {
            shipTypes = Dictionary(uniqueKeysWithValues: values.compactMap(Self.parseShipType).map { ($0.id, $0) })
            changed = true
        }
        if let values = object["api_mst_maparea"]?.arrayValue {
            mapAreas = Dictionary(uniqueKeysWithValues: values.compactMap(Self.parseMapArea).map { ($0.id, $0) })
            changed = true
        }
        if let values = object["api_mst_mapinfo"]?.arrayValue {
            maps = Dictionary(uniqueKeysWithValues: values.compactMap(Self.parseMap).map { ($0.id, $0) })
            changed = true
        }
        return changed
    }

    private static func parseShip(_ value: JSONValue) -> MasterShip? {
        guard let object = value.objectValue,
              let id = object.int("api_id") else { return nil }
        return MasterShip(
            id: id,
            name: object.string("api_name") ?? "",
            shipTypeID: object.int("api_stype") ?? 0,
            nextShipID: object.int("api_aftershipid"),
            speed: object.int("api_soku"),
            slotCount: object.int("api_slot_num"),
            fuelMaximum: object.int("api_fuel_max"),
            ammunitionMaximum: object.int("api_bull_max")
        )
    }

    private static func parseSlotItem(_ value: JSONValue) -> MasterSlotItem? {
        guard let object = value.objectValue,
              let id = object.int("api_id") else { return nil }
        return MasterSlotItem(
            id: id,
            name: object.string("api_name") ?? "",
            type: object.intArray("api_type"),
            antiSubmarine: object.int("api_tais")
        )
    }

    private static func parseShipType(_ value: JSONValue) -> MasterShipType? {
        guard let object = value.objectValue,
              let id = object.int("api_id") else { return nil }
        var equipmentTypes: [Int: Int] = [:]
        if let equipmentObject = object["api_equip_type"]?.objectValue {
            for (key, value) in equipmentObject {
                if let key = Int(key), let flag = value.intValue { equipmentTypes[key] = flag }
            }
        }
        return MasterShipType(
            id: id,
            name: object.string("api_name") ?? "",
            equipmentTypes: equipmentTypes
        )
    }

    private static func parseMapArea(_ value: JSONValue) -> MasterMapArea? {
        guard let object = value.objectValue,
              let id = object.int("api_id") else { return nil }
        return MasterMapArea(id: id, name: object.string("api_name") ?? "", type: object.int("api_type"))
    }

    private static func parseMap(_ value: JSONValue) -> MasterMap? {
        guard let object = value.objectValue,
              let id = object.int("api_id") else { return nil }
        return MasterMap(
            id: id,
            mapAreaID: object.int("api_maparea_id") ?? 0,
            number: object.int("api_no") ?? 0,
            name: object.string("api_name") ?? ""
        )
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func int64(_ key: String) -> Int64? { self[key]?.int64Value }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func intArray(_ key: String) -> [Int] {
        self[key]?.arrayValue?.compactMap(\.intValue) ?? []
    }
}
