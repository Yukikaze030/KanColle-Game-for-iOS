import Foundation

public struct MapGaugeState: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let mapAreaID: Int
    public let mapNumber: Int
    public let gaugeType: Int
    public let gaugeNumber: Int
    public let current: Int
    public let maximum: Int

    public var isTransport: Bool { gaugeType == 3 }
}

public struct LandAirPlaneState: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let slotItemID: Int?
    public let state: Int
    public let condition: Int?
}

public struct LandAirBaseState: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let areaID: Int
    public let name: String
    public let actionKind: Int
    public let distance: Int
    public let planes: [LandAirPlaneState]
}
