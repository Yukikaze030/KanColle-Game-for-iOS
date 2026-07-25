import Foundation

public struct GameDataState: Sendable, Equatable {
    public let master: GameMasterData
    public let fleet: FleetSnapshot
    public let revision: Int64

    public init(master: GameMasterData, fleet: FleetSnapshot, revision: Int64 = 0) {
        self.master = master
        self.fleet = fleet
        self.revision = revision
    }
}

public enum GameDataPipelineEvent: Sendable, Equatable {
    case masterDataUpdated
    case portUpdated
    case shipsAndDecksUpdated
    case slotItemsUpdated
    case decksUpdated
    case incrementalUpdated(endpoint: String, warnings: [String])
    case duplicate(eventID: String)
    case ignored(endpoint: String)
    case apiFailure(endpoint: String, result: Int, message: String?)
}

/// Serializes API replay and incremental state updates. The actor boundary is the only
/// mutation point, so WebKit callbacks may safely feed responses from arbitrary tasks.
public actor GameDataPipeline {
    private let parser: APIEnvelopeParser
    private let incrementalReducer: IncrementalStateReducer
    private let deduplicationCapacity: Int
    private var masterData = GameMasterData()
    private var fleetState = FleetSnapshot()
    private var revision: Int64 = 0
    private var recentEventIDs: [String] = []
    private var recentEventIDSet: Set<String> = []

    public init(
        parser: APIEnvelopeParser = APIEnvelopeParser(),
        incrementalReducer: IncrementalStateReducer = IncrementalStateReducer(),
        deduplicationCapacity: Int = 128
    ) {
        self.parser = parser
        self.incrementalReducer = incrementalReducer
        self.deduplicationCapacity = max(1, deduplicationCapacity)
    }

    @discardableResult
    public func ingest(
        endpoint: String,
        response: Data,
        requestBody: Data? = nil,
        eventID: String? = nil
    ) throws -> GameDataPipelineEvent {
        if let eventID, recentEventIDSet.contains(eventID) {
            return .duplicate(eventID: eventID)
        }

        let envelope = try parser.parse(endpoint: endpoint, response: response, requestBody: requestBody)
        if let result = envelope.apiResult, result != 1 {
            return .apiFailure(endpoint: envelope.endpoint, result: result, message: envelope.apiResultMessage)
        }
        switch envelope.endpoint {
        case "/api_start2", "/api_start2/getData":
            guard let data = envelope.data else { return .ignored(endpoint: envelope.endpoint) }
            guard masterData.applyStart2(data) else { return .ignored(endpoint: envelope.endpoint) }
            return commit(.masterDataUpdated, eventID: eventID)

        case "/api_port/port":
            guard let data = envelope.data else { return .ignored(endpoint: envelope.endpoint) }
            guard let object = data.objectValue else { return .ignored(endpoint: envelope.endpoint) }
            applyPort(object)
            return commit(.portUpdated, eventID: eventID)

        case "/api_get_member/require_info":
            guard let data = envelope.data else { return .ignored(endpoint: envelope.endpoint) }
            guard let object = data.objectValue,
                  let items = object["api_slot_item"]?.arrayValue else {
                return .ignored(endpoint: envelope.endpoint)
            }
            fleetState.replaceSlotItems(from: items)
            return commit(.slotItemsUpdated, eventID: eventID)

        default:
            let reduction = incrementalReducer.reduce(envelope: envelope, state: &fleetState)
            guard reduction.recognized else {
                return .ignored(endpoint: envelope.endpoint)
            }
            guard reduction.applied else {
                return .incrementalUpdated(endpoint: envelope.endpoint, warnings: reduction.warnings)
            }

            let event: GameDataPipelineEvent
            switch envelope.endpoint {
            case "/api_get_member/ship_deck", "/api_get_member/ship2", "/api_get_member/ship3":
                event = .shipsAndDecksUpdated
            case "/api_get_member/slot_item":
                event = .slotItemsUpdated
            case "/api_get_member/deck":
                event = .decksUpdated
            default:
                event = .incrementalUpdated(endpoint: envelope.endpoint, warnings: reduction.warnings)
            }
            return commit(event, eventID: eventID)
        }
    }

    public func state() -> GameDataState {
        GameDataState(master: masterData, fleet: fleetState, revision: revision)
    }

    public func masterSnapshot() -> GameMasterData { masterData }
    public func fleetSnapshot() -> FleetSnapshot { fleetState }

    public func reset() {
        masterData = GameMasterData()
        fleetState = FleetSnapshot()
        revision = 0
        recentEventIDs.removeAll(keepingCapacity: true)
        recentEventIDSet.removeAll(keepingCapacity: true)
    }

    private func commit(_ event: GameDataPipelineEvent, eventID: String?) -> GameDataPipelineEvent {
        revision &+= 1
        if let eventID {
            remember(eventID)
        }
        return event
    }

    private func remember(_ eventID: String) {
        guard recentEventIDSet.insert(eventID).inserted else { return }
        recentEventIDs.append(eventID)
        if recentEventIDs.count > deduplicationCapacity {
            let evicted = recentEventIDs.removeFirst()
            recentEventIDSet.remove(evicted)
        }
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
