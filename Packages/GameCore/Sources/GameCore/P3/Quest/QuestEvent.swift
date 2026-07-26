import Foundation

/// A stable semantic event produced at the API boundary. Quest reducers deliberately
/// consume this type instead of matching endpoint strings or decoding game JSON.
public struct QuestEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let occurredAt: Date
    public let kind: Kind

    public init(id: String, occurredAt: Date, kind: Kind) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case sortieStarted(deckID: Int?, world: Int?, map: Int?)
        case nodeReached(world: Int?, map: Int?, node: Int?)
        case battleFinished(rank: String?, isBoss: Bool?)
        case practiceFinished(rank: String?)
        case expeditionStarted(missionID: Int?, deckID: Int?)
        case expeditionFinished(missionID: Int?, succeeded: Bool)
        case dockingStarted(shipID: Int?, highSpeed: Bool)
        case supplied(shipCount: Int)
        case itemDeveloped(attemptCount: Int, successCount: Int)
        case itemDiscarded(itemInstanceIDs: [Int])
        case shipBuilt(dockID: Int?, isLarge: Bool)
        case shipAcquired(masterShipID: Int?)
        case shipDiscarded(shipInstanceIDs: [Int])
        case equipmentImproved(succeeded: Bool)
        case modernizationCompleted(succeeded: Bool)
    }
}
