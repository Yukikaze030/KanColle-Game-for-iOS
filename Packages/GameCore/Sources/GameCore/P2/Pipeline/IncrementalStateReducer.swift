import Foundation

/// Result of one endpoint-specific reduction. A recognized but malformed message is not
/// committed, while a partially valid collection may commit its valid members and expose
/// warnings for the rejected members.
public struct IncrementalStateReduction: Sendable, Equatable {
    public let recognized: Bool
    public let applied: Bool
    public let warnings: [String]

    public init(recognized: Bool, applied: Bool, warnings: [String] = []) {
        self.recognized = recognized
        self.applied = applied
        self.warnings = warnings
    }

    static func ignored() -> Self {
        Self(recognized: false, applied: false)
    }

    static func rejected(_ warning: String) -> Self {
        Self(recognized: true, applied: false, warnings: [warning])
    }
}

/// Applies the P2 APIs that mutate an already-loaded port snapshot.
///
/// The reducer is deliberately a value type with no hidden cache. Ordering, revision
/// assignment and event-id de-duplication belong to `GameDataPipeline`'s actor boundary.
public struct IncrementalStateReducer: Sendable {
    public init() {}

    public func reduce(
        envelope: APIEnvelope,
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        switch envelope.endpoint {
        case "/api_get_member/deck":
            guard let decks = envelope.data?.arrayValue else {
                return .rejected("deck response is not an array")
            }
            state.replaceDecks(from: decks)
            return committed()

        case "/api_get_member/ship_deck", "/api_get_member/ship2", "/api_get_member/ship3":
            return reduceShipsAndDecks(envelope.data, endpoint: envelope.endpoint, state: &state)

        case "/api_get_member/slot_item":
            guard let items = envelope.data?.arrayValue else {
                return .rejected("slot_item response is not an array")
            }
            state.replaceSlotItems(from: items)
            return committed()

        case "/api_req_hokyu/charge":
            return reduceCharge(envelope.data, state: &state)

        case "/api_req_hensei/change":
            return reduceCompositionChange(envelope.requestParameters, state: &state)

        case "/api_req_hensei/preset_select":
            return reducePreset(envelope.data, request: envelope.requestParameters, state: &state)

        case "/api_get_member/ndock":
            guard let docks = envelope.data?.arrayValue else {
                return .rejected("ndock response is not an array")
            }
            state.replaceRepairDocks(from: docks)
            return committed()

        case "/api_req_nyukyo/start":
            return reduceDockStart(envelope.data, request: envelope.requestParameters, state: &state)

        case "/api_req_nyukyo/speedchange":
            return reduceDockSpeedChange(envelope.requestParameters, state: &state)

        case "/api_req_mission/return_instruction":
            return reduceMissionReturn(envelope.data, request: envelope.requestParameters, state: &state)

        case "/api_req_mission/result":
            return reduceMissionResult(envelope.requestParameters, state: &state)

        case "/api_req_member/itemuse_cond":
            return reduceConditionItem(envelope.data, request: envelope.requestParameters, state: &state)

        default:
            return .ignored()
        }
    }

    private func reduceShipsAndDecks(
        _ data: JSONValue?,
        endpoint: String,
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        var warnings: [String] = []
        var foundCollection = false

        if let ships = data?.arrayValue {
            state.mergeShips(from: ships)
            foundCollection = true
        } else if let object = data?.objectValue {
            if let ships = object["api_ship_data"]?.arrayValue
                ?? object["api_ship"]?.arrayValue
                ?? object["api_ship_data_list"]?.arrayValue {
                state.mergeShips(from: ships)
                foundCollection = true
            }
            if let decks = object["api_deck_data"]?.arrayValue
                ?? object["api_data_deck"]?.arrayValue {
                state.mergeDecks(from: decks)
                foundCollection = true
            }
        }

        guard foundCollection else {
            warnings.append("\(endpoint) contains neither ship nor deck data")
            return IncrementalStateReduction(recognized: true, applied: false, warnings: warnings)
        }
        return committed(warnings)
    }

    private func reduceCharge(
        _ data: JSONValue?,
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let ships = data?.objectValue?["api_ship"]?.arrayValue else {
            return .rejected("charge response has no api_ship array")
        }

        var warnings: [String] = []
        var applied = false
        for value in ships {
            guard let object = value.objectValue, let shipID = object.int("api_id") else {
                warnings.append("charge contains a ship without api_id")
                continue
            }
            guard state.ships[shipID] != nil else {
                warnings.append("charge references unknown ship \(shipID)")
                continue
            }
            state.mergeShips(from: [value])
            applied = true
        }
        return IncrementalStateReduction(recognized: true, applied: applied, warnings: warnings)
    }

    private func reduceCompositionChange(
        _ request: [String: String],
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let deckID = integer("api_id", in: request),
              let shipIndex = integer("api_ship_idx", in: request),
              let shipID = integer("api_ship_id", in: request) else {
            return .rejected("hensei/change request is missing api_id, api_ship_idx or api_ship_id")
        }
        guard let targetDeck = state.decks[deckID] else {
            return .rejected("hensei/change references unknown deck \(deckID)")
        }

        if shipID == -2 {
            guard let flagship = targetDeck.shipIDs.first else {
                return .rejected("hensei/change cannot clear an empty deck")
            }
            state.setDeckShipIDs(deckID: deckID, shipIDs: [flagship])
            return committed()
        }

        guard shipIndex >= 0 else {
            return .rejected("hensei/change has negative ship index \(shipIndex)")
        }

        if shipID == -1 {
            guard shipIndex < targetDeck.shipIDs.count else {
                return .rejected("hensei/change remove index \(shipIndex) is out of range")
            }
            var ships = targetDeck.shipIDs
            ships.remove(at: shipIndex)
            state.setDeckShipIDs(deckID: deckID, shipIDs: ships)
            return committed()
        }

        guard shipID > 0 else {
            return .rejected("hensei/change has unsupported ship id \(shipID)")
        }
        guard state.ships[shipID] != nil else {
            return .rejected("hensei/change references unknown ship \(shipID)")
        }
        guard shipIndex <= targetDeck.shipIDs.count else {
            return .rejected("hensei/change target index \(shipIndex) is out of range")
        }

        var deckShips = state.decks.mapValues(\.shipIDs)
        let source = deckShips
            .sorted { $0.key < $1.key }
            .compactMap { deckID, ships -> (Int, Int)? in
                ships.firstIndex(of: shipID).map { (deckID, $0) }
            }
            .first
        let displacedShipID = shipIndex < targetDeck.shipIDs.count
            ? targetDeck.shipIDs[shipIndex]
            : nil

        if let source {
            if source.0 == deckID {
                var ships = deckShips[deckID] ?? []
                if source.1 == shipIndex { return committed() }
                if shipIndex < ships.count {
                    ships.swapAt(source.1, shipIndex)
                } else {
                    ships.remove(at: source.1)
                    ships.append(shipID)
                }
                deckShips[deckID] = ships
            } else {
                var sourceShips = deckShips[source.0] ?? []
                if let displacedShipID {
                    sourceShips[source.1] = displacedShipID
                } else {
                    sourceShips.remove(at: source.1)
                }
                deckShips[source.0] = sourceShips

                var targetShips = deckShips[deckID] ?? []
                if shipIndex < targetShips.count {
                    targetShips[shipIndex] = shipID
                } else {
                    targetShips.append(shipID)
                }
                deckShips[deckID] = targetShips
            }
        } else {
            var ships = deckShips[deckID] ?? []
            if shipIndex < ships.count {
                ships[shipIndex] = shipID
            } else {
                ships.append(shipID)
            }
            deckShips[deckID] = ships
        }

        for (id, ships) in deckShips {
            state.setDeckShipIDs(deckID: id, shipIDs: ships)
        }
        return committed()
    }

    private func reducePreset(
        _ data: JSONValue?,
        request: [String: String],
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let deckID = integer("api_deck_id", in: request) else {
            return .rejected("preset_select request is missing api_deck_id")
        }
        guard state.decks[deckID] != nil else {
            return .rejected("preset_select references unknown deck \(deckID)")
        }
        guard let object = data?.objectValue else {
            return .rejected("preset_select response is not an object")
        }

        var normalized = object
        if normalized["api_id"] == nil { normalized["api_id"] = .integer(Int64(deckID)) }
        guard let deck = parseDeck(.object(normalized), previous: state.decks[deckID]) else {
            return .rejected("preset_select response has no usable deck")
        }

        let unknown = deck.shipIDs.filter { state.ships[$0] == nil }
        guard unknown.isEmpty else {
            return .rejected("preset_select references unknown ships \(unknown)")
        }

        // A preset may pull ships from other fleets. Remove them there before replacing
        // the destination deck to keep one-ship-one-fleet consistency.
        for (otherID, otherDeck) in state.decks where otherID != deckID {
            let filtered = otherDeck.shipIDs.filter { !deck.shipIDs.contains($0) }
            state.setDeckShipIDs(deckID: otherID, shipIDs: filtered)
        }
        state.replaceDeck(deck)
        return committed()
    }

    private func reduceDockStart(
        _ data: JSONValue?,
        request: [String: String],
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let dockID = integer("api_ndock_id", in: request),
              let shipID = integer("api_ship_id", in: request),
              let highSpeed = integer("api_highspeed", in: request) else {
            return .rejected("nyukyo/start request is missing dock, ship or highspeed")
        }
        guard let ship = state.ships[shipID] else {
            return .rejected("nyukyo/start references unknown ship \(shipID)")
        }
        guard dockID > 0 else {
            return .rejected("nyukyo/start has invalid dock \(dockID)")
        }

        if highSpeed > 0 {
            state.updateShip(id: shipID, currentHP: ship.maximumHP, condition: max(40, ship.condition))
            state.setRepairDock(RepairDock(id: dockID, state: 0, shipID: nil, completionTime: nil))
            return committed()
        }

        let responseObject = data?.objectValue
        let dockObject = responseObject?["api_ndock"]?.objectValue ?? responseObject
        let completion = dockObject?.int64("api_complete_time").flatMap { $0 > 0 ? $0 : nil }
        state.setRepairDock(RepairDock(id: dockID, state: 1, shipID: shipID, completionTime: completion))
        return committed()
    }

    private func reduceDockSpeedChange(
        _ request: [String: String],
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let dockID = integer("api_ndock_id", in: request) else {
            return .rejected("nyukyo/speedchange request is missing api_ndock_id")
        }
        guard let dock = state.repairDocks[dockID] else {
            return .rejected("nyukyo/speedchange references unknown dock \(dockID)")
        }
        var warnings: [String] = []
        if let shipID = dock.shipID, let ship = state.ships[shipID] {
            state.updateShip(id: shipID, currentHP: ship.maximumHP)
        } else if let shipID = dock.shipID {
            warnings.append("nyukyo/speedchange dock \(dockID) references unknown ship \(shipID)")
        }
        state.setRepairDock(RepairDock(id: dockID, state: 0, shipID: nil, completionTime: nil))
        return committed(warnings)
    }

    private func reduceMissionReturn(
        _ data: JSONValue?,
        request: [String: String],
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let missionValues = data?.objectValue?["api_mission"]?.arrayValue?.compactMap(\.int64Value),
              missionValues.count >= 3 else {
            return .rejected("return_instruction response has no complete api_mission tuple")
        }
        let mission = ExpeditionState(
            status: Int(exactly: missionValues[0]) ?? 0,
            missionID: Int(exactly: missionValues[1]) ?? 0,
            completionTime: missionValues[2] > 0 ? missionValues[2] : nil
        )
        let requestedDeckID = integer("api_deck_id", in: request)
        let deckID = requestedDeckID ?? state.decks
            .first(where: { $0.value.expedition?.missionID == mission.missionID })?.key
        guard let deckID, state.decks[deckID] != nil else {
            return .rejected("return_instruction cannot resolve expedition deck")
        }
        state.setDeckExpedition(deckID: deckID, expedition: mission)
        return committed()
    }

    private func reduceMissionResult(
        _ request: [String: String],
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let deckID = integer("api_deck_id", in: request) else {
            return .rejected("mission/result request is missing api_deck_id")
        }
        guard state.decks[deckID] != nil else {
            return .rejected("mission/result references unknown deck \(deckID)")
        }
        state.setDeckExpedition(deckID: deckID, expedition: nil)
        return committed()
    }

    private func reduceConditionItem(
        _ data: JSONValue?,
        request: [String: String],
        state: inout FleetSnapshot
    ) -> IncrementalStateReduction {
        guard let deckID = integer("api_deck_id", in: request),
              let deck = state.decks[deckID] else {
            return .rejected("itemuse_cond request has an unknown or missing api_deck_id")
        }

        var warnings: [String] = []
        var applied = false
        if let object = data?.objectValue {
            if let ships = object["api_ship"]?.arrayValue {
                for value in ships {
                    guard let id = value.objectValue?.int("api_id"), state.ships[id] != nil else {
                        warnings.append("itemuse_cond contains an unknown ship")
                        continue
                    }
                    state.mergeShips(from: [value])
                    applied = true
                }
            }
            if let conditions = object["api_cond"]?.arrayValue?.compactMap(\.intValue) {
                for (shipID, condition) in zip(deck.shipIDs, conditions) {
                    if state.updateShip(id: shipID, condition: condition) {
                        applied = true
                    } else if state.ships[shipID] == nil {
                        warnings.append("itemuse_cond references unknown ship \(shipID)")
                    }
                }
                // A well-formed condition projection is an accepted event even if values
                // happen to equal the previous snapshot.
                applied = applied || !conditions.isEmpty
            }
        } else if let ships = data?.arrayValue {
            for value in ships {
                guard let id = value.objectValue?.int("api_id"), state.ships[id] != nil else {
                    warnings.append("itemuse_cond contains an unknown ship")
                    continue
                }
                state.mergeShips(from: [value])
                applied = true
            }
        }
        guard applied else {
            warnings.append("itemuse_cond response contains no condition update")
            return IncrementalStateReduction(recognized: true, applied: false, warnings: warnings)
        }
        return committed(warnings)
    }

    private func integer(_ key: String, in request: [String: String]) -> Int? {
        request[key].flatMap(Int.init)
    }

    private func committed(_ warnings: [String] = []) -> IncrementalStateReduction {
        IncrementalStateReduction(recognized: true, applied: true, warnings: warnings)
    }

    /// Mirrors `FleetSnapshot.parseDeck` without exposing parsing as public API.
    private func parseDeck(_ value: JSONValue, previous: FleetDeck?) -> FleetDeck? {
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
}
