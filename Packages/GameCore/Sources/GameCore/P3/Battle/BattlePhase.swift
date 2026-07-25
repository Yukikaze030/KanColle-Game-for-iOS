import Foundation

public enum BattlePhaseKind: String, Codable, Sendable {
    case initialization
    case airBase
    case aerial
    case support
    case openingAntiSubmarine
    case openingTorpedo
    case shelling
    case torpedo
    case friendlyFleet
    case night
}

public struct DamageEvent: Codable, Equatable, Sendable {
    public let target: BattleShipPosition
    public let targetIsFriendly: Bool
    public let damage: Int
}

public struct BattlePhaseResult: Codable, Equatable, Sendable {
    public let kind: BattlePhaseKind
    public let events: [DamageEvent]
    public let warnings: [BattleParseWarning]

    public init(
        kind: BattlePhaseKind,
        events: [DamageEvent] = [],
        warnings: [BattleParseWarning] = []
    ) {
        self.kind = kind
        self.events = events
        self.warnings = warnings
    }
}
