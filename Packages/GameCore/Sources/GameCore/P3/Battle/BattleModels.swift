import Foundation

public enum BattleFleetComponent: String, Codable, Sendable {
    case main
    case escort
}

public struct BattleShipPosition: Codable, Hashable, Sendable {
    public let component: BattleFleetComponent
    public let index: Int

    public init(component: BattleFleetComponent, index: Int) {
        self.component = component
        self.index = index
    }
}

public enum BattleShipIdentity: Codable, Hashable, Sendable {
    case friendlyUserShip(Int)
    case enemyMasterShip(masterID: Int?, position: BattleShipPosition)
}

public struct BattleShipState: Codable, Equatable, Identifiable, Sendable {
    public var id: BattleShipIdentity
    public let position: BattleShipPosition
    public let masterShipID: Int?
    public let level: Int?
    public let maximumHP: Int
    public let initialHP: Int
    public var currentHP: Int
    public var escaped: Bool

    public init(
        id: BattleShipIdentity,
        position: BattleShipPosition,
        masterShipID: Int?,
        level: Int?,
        maximumHP: Int,
        initialHP: Int,
        currentHP: Int,
        escaped: Bool = false
    ) {
        self.id = id
        self.position = position
        self.masterShipID = masterShipID
        self.level = level
        self.maximumHP = maximumHP
        self.initialHP = initialHP
        self.currentHP = currentHP
        self.escaped = escaped
    }
}

public struct BattleFleetState: Codable, Equatable, Sendable {
    public var ships: [BattleShipState]
    public init(ships: [BattleShipState] = []) { self.ships = ships }
}

public enum BattleKind: String, Codable, Sendable {
    case sortie
    case practice
}

public struct BattleMapPosition: Codable, Equatable, Sendable {
    public let deckID: Int?
    public let mapAreaID: Int?
    public let mapNumber: Int?
    public let nodeID: Int?
    public let eventID: Int?
    public let eventKind: Int?
    public let isBoss: Bool

    public init(
        deckID: Int? = nil,
        mapAreaID: Int? = nil,
        mapNumber: Int? = nil,
        nodeID: Int? = nil,
        eventID: Int? = nil,
        eventKind: Int? = nil,
        isBoss: Bool = false
    ) {
        self.deckID = deckID
        self.mapAreaID = mapAreaID
        self.mapNumber = mapNumber
        self.nodeID = nodeID
        self.eventID = eventID
        self.eventKind = eventKind
        self.isBoss = isBoss
    }
}

public struct BattleFormation: Codable, Equatable, Sendable {
    public let friendly: Int
    public let enemy: Int
    public let engagement: Int
}

public enum BattleSessionStatus: String, Codable, Sendable {
    case active
    case awaitingResult
    case completed
}

public struct BattleParseWarning: Codable, Equatable, Sendable {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

public struct BattleSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var endpoint: BattleEndpoint
    public var kind: BattleKind
    public var map: BattleMapPosition?
    public var formation: BattleFormation?
    public var friendlyMain: BattleFleetState
    public var friendlyEscort: BattleFleetState?
    public var enemyMain: BattleFleetState
    public var enemyEscort: BattleFleetState?
    public var phases: [BattlePhaseResult]
    public var status: BattleSessionStatus
    public var warnings: [BattleParseWarning]
    public var revision: Int64
}
