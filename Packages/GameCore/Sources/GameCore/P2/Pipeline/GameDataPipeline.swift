import Foundation

public struct GameDataState: Codable, Sendable, Equatable {
    public let master: GameMasterData
    public let fleet: FleetSnapshot
    public let mapGauges: [MapGaugeState]
    public let landAirBases: [LandAirBaseState]
    public let revision: Int64

    public init(master: GameMasterData, fleet: FleetSnapshot, mapGauges: [MapGaugeState] = [], landAirBases: [LandAirBaseState] = [], revision: Int64 = 0) {
        self.master = master
        self.fleet = fleet
        self.mapGauges = mapGauges
        self.landAirBases = landAirBases
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case master, fleet, mapGauges, landAirBases, revision }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        master = try values.decode(GameMasterData.self, forKey: .master)
        fleet = try values.decode(FleetSnapshot.self, forKey: .fleet)
        mapGauges = try values.decodeIfPresent([MapGaugeState].self, forKey: .mapGauges) ?? []
        landAirBases = try values.decodeIfPresent([LandAirBaseState].self, forKey: .landAirBases) ?? []
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
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
    private var mapGauges: [MapGaugeState] = []
    private var landAirBases: [LandAirBaseState] = []
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
        let envelope = try parser.parse(endpoint: endpoint, response: response, requestBody: requestBody)
        return ingest(envelope: envelope, eventID: eventID)
    }

    /// Accepts an already parsed envelope so the App coordinator can fan one
    /// validated response into P2 fleet, P3 battle and P3 quest reducers without
    /// parsing or retaining the raw response more than once.
    public func ingest(
        envelope: APIEnvelope,
        eventID: String? = nil
    ) -> GameDataPipelineEvent {
        if let eventID, recentEventIDSet.contains(eventID) {
            return .duplicate(eventID: eventID)
        }

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

        // These values are refreshed separately by the game after a map is selected,
        // so only accepting the port payload leaves the native map/air-base tools stale.
        case "/api_get_member/mapinfo", "/api_get_member/base_air_corps":
            guard let data = envelope.data,
                  let object = data.objectValue else { return .ignored(endpoint: envelope.endpoint) }
            guard applySortieSupport(object) else { return .ignored(endpoint: envelope.endpoint) }
            return commit(.incrementalUpdated(endpoint: envelope.endpoint, warnings: []), eventID: eventID)

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
        GameDataState(master: masterData, fleet: fleetState, mapGauges: mapGauges, landAirBases: landAirBases, revision: revision)
    }

    public func masterSnapshot() -> GameMasterData { masterData }
    public func fleetSnapshot() -> FleetSnapshot { fleetState }

    public func reset() {
        masterData = GameMasterData()
        fleetState = FleetSnapshot()
        mapGauges = []
        landAirBases = []
        revision = 0
        recentEventIDs.removeAll(keepingCapacity: true)
        recentEventIDSet.removeAll(keepingCapacity: true)
    }

    /// Restores the last atomically persisted baseline before new WebKit events
    /// arrive. Event de-duplication intentionally starts fresh for each process.
    public func restore(_ state: GameDataState) {
        masterData = state.master
        fleetState = state.fleet
        mapGauges = state.mapGauges
        landAirBases = state.landAirBases
        revision = max(0, state.revision)
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
        _ = applySortieSupport(object)
    }

    @discardableResult
    private func applySortieSupport(_ object: [String: JSONValue]) -> Bool {
        var changed = false
        if let maps = object["api_map_info"]?.arrayValue {
            let next = maps.compactMap(Self.mapGauge)
            if next != mapGauges { mapGauges = next; changed = true }
        }
        // `base_air_corps` returns its array under api_air_corps on some game versions.
        if let bases = object["api_air_base"]?.arrayValue ?? object["api_air_corps"]?.arrayValue {
            let next = bases.compactMap(Self.landAirBase)
            if next != landAirBases { landAirBases = next; changed = true }
        }
        return changed
    }

    private static func mapGauge(_ value: JSONValue) -> MapGaugeState? {
        guard let object = value.objectValue,
              let id = object.int("api_id") else { return nil }
        let event = object["api_eventmap"]?.objectValue
        let current = event?.int("api_now_maphp")
            ?? object.int("api_required_defeat_count").flatMap { total in object.int("api_defeat_count").map { total - $0 } }
        let maximum = event?.int("api_max_maphp") ?? object.int("api_required_defeat_count")
        guard let current, let maximum, maximum > 0 else { return nil }
        let gaugeType: Int = event?.int("api_gauge_type") ?? object.int("api_gauge_type") ?? 0
        let gaugeNumber: Int = event?.int("api_gauge_num") ?? object.int("api_gauge_num") ?? 0
        return MapGaugeState(
            id: id,
            mapAreaID: id / 10,
            mapNumber: id % 10,
            gaugeType: gaugeType,
            gaugeNumber: gaugeNumber,
            current: max(0, current),
            maximum: maximum
        )
    }

    private static func landAirBase(_ value: JSONValue) -> LandAirBaseState? {
        guard let object = value.objectValue,
              let id = object.int("api_rid") else { return nil }
        let distance = object["api_distance"]?.objectValue
        let planes: [LandAirPlaneState] = object["api_plane_info"]?.arrayValue?.enumerated().map { index, plane in
            let info = plane.objectValue
            return LandAirPlaneState(id: id * 10 + index, slotItemID: info?.int("api_slotid"), state: info?.int("api_state") ?? 0, condition: info?.int("api_cond"))
        } ?? []
        let areaID = object.int("api_area_id") ?? 0
        let name = object.string("api_name") ?? "基地航空队"
        let actionKind = object.int("api_action_kind") ?? 0
        let range = (distance?.int("api_base") ?? 0) + (distance?.int("api_bonus") ?? 0)
        return .init(id: id, areaID: areaID, name: name, actionKind: actionKind, distance: range, planes: planes)
    }
}
