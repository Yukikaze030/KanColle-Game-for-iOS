import Foundation

public struct GameDataState: Sendable, Equatable {
    public let master: GameMasterData
    public let fleet: FleetSnapshot

    public init(master: GameMasterData, fleet: FleetSnapshot) {
        self.master = master
        self.fleet = fleet
    }
}

public enum GameDataPipelineEvent: Sendable, Equatable {
    case masterDataUpdated
    case portUpdated
    case shipsAndDecksUpdated
    case slotItemsUpdated
    case decksUpdated
    case ignored(endpoint: String)
    case apiFailure(endpoint: String, result: Int, message: String?)
}

/// Serializes API replay and incremental state updates. The actor boundary is the only
/// mutation point, so WebKit callbacks may safely feed responses from arbitrary tasks.
public actor GameDataPipeline {
    private let parser: APIEnvelopeParser
    private var masterData = GameMasterData()
    private var fleetState = FleetSnapshot()

    public init(parser: APIEnvelopeParser = APIEnvelopeParser()) {
        self.parser = parser
    }

    @discardableResult
    public func ingest(
        endpoint: String,
        response: Data,
        requestBody: Data? = nil
    ) throws -> GameDataPipelineEvent {
        let envelope = try parser.parse(endpoint: endpoint, response: response, requestBody: requestBody)
        if let result = envelope.apiResult, result != 1 {
            return .apiFailure(endpoint: envelope.endpoint, result: result, message: envelope.apiResultMessage)
        }
        guard let data = envelope.data else {
            return .ignored(endpoint: envelope.endpoint)
        }

        switch envelope.endpoint {
        case "/api_start2", "/api_start2/getData":
            guard masterData.applyStart2(data) else { return .ignored(endpoint: envelope.endpoint) }
            return .masterDataUpdated

        case "/api_port/port":
            guard let object = data.objectValue else { return .ignored(endpoint: envelope.endpoint) }
            applyPort(object)
            return .portUpdated

        case "/api_get_member/ship_deck":
            guard let object = data.objectValue else { return .ignored(endpoint: envelope.endpoint) }
            if let ships = object["api_ship_data"]?.arrayValue { fleetState.mergeShips(from: ships) }
            if let decks = object["api_deck_data"]?.arrayValue { fleetState.mergeDecks(from: decks) }
            return .shipsAndDecksUpdated

        case "/api_get_member/slot_item":
            guard let items = data.arrayValue else { return .ignored(endpoint: envelope.endpoint) }
            fleetState.replaceSlotItems(from: items)
            return .slotItemsUpdated

        case "/api_get_member/deck":
            guard let decks = data.arrayValue else { return .ignored(endpoint: envelope.endpoint) }
            fleetState.replaceDecks(from: decks)
            return .decksUpdated

        case "/api_get_member/require_info":
            guard let object = data.objectValue,
                  let items = object["api_slot_item"]?.arrayValue else {
                return .ignored(endpoint: envelope.endpoint)
            }
            fleetState.replaceSlotItems(from: items)
            return .slotItemsUpdated

        default:
            return .ignored(endpoint: envelope.endpoint)
        }
    }

    public func state() -> GameDataState {
        GameDataState(master: masterData, fleet: fleetState)
    }

    public func masterSnapshot() -> GameMasterData { masterData }
    public func fleetSnapshot() -> FleetSnapshot { fleetState }

    public func reset() {
        masterData = GameMasterData()
        fleetState = FleetSnapshot()
    }

    private func applyPort(_ object: [String: JSONValue]) {
        if let basic = object["api_basic"] { fleetState.updateAdmiral(from: basic) }
        if let ships = object["api_ship"]?.arrayValue { fleetState.replaceShips(from: ships) }
        if let items = object["api_slot_item"]?.arrayValue ?? object["api_slotitem"]?.arrayValue {
            fleetState.replaceSlotItems(from: items)
        }
        if let decks = object["api_deck_port"]?.arrayValue { fleetState.replaceDecks(from: decks) }
        if let docks = object["api_ndock"]?.arrayValue { fleetState.replaceRepairDocks(from: docks) }
        if let combined = object.int("api_combined_flag") { fleetState.combinedFleetType = combined }
    }
}
