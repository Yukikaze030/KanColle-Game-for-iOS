import Foundation

/// Converts raw API envelopes into platform-independent quest events. This is the sole
/// layer that understands endpoint names, request parameters and response field names.
public struct QuestEventRouter: Sendable {
    private static let battleResultEndpoints: Set<String> = [
        "/api_req_sortie/battleresult", "/api_req_combined_battle/battleresult"
    ]

    public init() {}

    /// Returns every semantic event represented by an API call. Map start and battle
    /// result can intentionally emit more than one event (start + first node, or battle
    /// result + ship drop) while retaining deterministic derived IDs.
    public func routeAll(
        envelope: APIEnvelope,
        eventID: String,
        occurredAt: Date = Date()
    ) -> [QuestEvent] {
        guard envelope.apiResult == nil || envelope.apiResult == 1 else { return [] }
        guard let primary = routePrimary(envelope: envelope, eventID: eventID, occurredAt: occurredAt) else {
            return []
        }
        var events = [primary]
        let object = envelope.data?.objectValue
        if envelope.endpoint == "/api_req_map/start" {
            events.append(QuestEvent(
                id: eventID + "#node",
                occurredAt: occurredAt,
                kind: .nodeReached(
                    world: object?.int("api_maparea_id") ?? integer(envelope.requestParameters["api_maparea_id"]),
                    map: object?.int("api_mapinfo_no") ?? integer(envelope.requestParameters["api_mapinfo_no"]),
                    node: object?.int("api_no") ?? object?.int("api_next")
                )
            ))
        }
        if Self.battleResultEndpoints.contains(envelope.endpoint),
           let drop = object?["api_get_ship"]?.objectValue,
           let masterID = drop.int("api_ship_id"), masterID > 0 {
            events.append(QuestEvent(
                id: eventID + "#ship",
                occurredAt: occurredAt,
                kind: .shipAcquired(masterShipID: masterID)
            ))
        }
        return events
    }

    /// Convenience for endpoints that represent a single primary event.
    public func route(
        envelope: APIEnvelope,
        eventID: String,
        occurredAt: Date = Date()
    ) -> QuestEvent? {
        routeAll(envelope: envelope, eventID: eventID, occurredAt: occurredAt).first
    }

    private func routePrimary(
        envelope: APIEnvelope,
        eventID: String,
        occurredAt: Date
    ) -> QuestEvent? {
        let request = envelope.requestParameters
        let object = envelope.data?.objectValue
        let kind: QuestEvent.Kind

        switch envelope.endpoint {
        case "/api_req_map/start":
            kind = .sortieStarted(
                deckID: integer(request["api_deck_id"]),
                world: integer(request["api_maparea_id"]),
                map: integer(request["api_mapinfo_no"])
            )
        case "/api_req_map/next":
            kind = .nodeReached(
                world: object?.int("api_maparea_id") ?? integer(request["api_maparea_id"]),
                map: object?.int("api_mapinfo_no") ?? integer(request["api_mapinfo_no"]),
                node: object?.int("api_no") ?? object?.int("api_next")
            )
        case let endpoint where Self.battleResultEndpoints.contains(endpoint):
            kind = .battleFinished(
                rank: object?.string("api_win_rank"),
                isBoss: object?.int("api_boss_flag").map { $0 != 0 }
            )
        case "/api_req_practice/battle_result":
            kind = .practiceFinished(rank: object?.string("api_win_rank"))
        case "/api_req_mission/start":
            kind = .expeditionStarted(
                missionID: integer(request["api_mission_id"]),
                deckID: integer(request["api_deck_id"])
            )
        case "/api_req_mission/result":
            let clearResult = object?.int("api_clear_result") ?? 0
            kind = .expeditionFinished(
                missionID: object?.int("api_quest_id") ?? integer(request["api_mission_id"]),
                succeeded: clearResult > 0
            )
        case "/api_req_nyukyo/start":
            kind = .dockingStarted(
                shipID: integer(request["api_ship_id"]),
                highSpeed: integer(request["api_highspeed"]) == 1
            )
        case "/api_req_hokyu/charge":
            kind = .supplied(shipCount: max(1, commaSeparatedIntegers(request["api_id"]).count))
        case "/api_req_kousyou/createitem":
            let attempts = developmentAttempts(object)
            kind = .itemDeveloped(attemptCount: attempts.count, successCount: attempts.filter(\.self).count)
        case "/api_req_kousyou/destroyitem2":
            kind = .itemDiscarded(itemInstanceIDs: commaSeparatedIntegers(request["api_slotitem_ids"]))
        case "/api_req_kousyou/createship":
            kind = .shipBuilt(
                dockID: integer(request["api_kdock_id"]),
                isLarge: integer(request["api_large_flag"]) == 1
            )
        case "/api_req_kousyou/getship":
            let ship = object?["api_ship"]?.objectValue
            kind = .shipAcquired(masterShipID: ship?.int("api_ship_id") ?? object?.int("api_ship_id"))
        case "/api_req_kousyou/destroyship":
            kind = .shipDiscarded(shipInstanceIDs: commaSeparatedIntegers(request["api_ship_id"]))
        case "/api_req_kousyou/remodel_slot":
            kind = .equipmentImproved(succeeded: object?.int("api_remodel_flag") == 1)
        case "/api_req_kaisou/powerup":
            kind = .modernizationCompleted(succeeded: object?.int("api_powerup_flag") == 1)
        default:
            return nil
        }
        return QuestEvent(id: eventID, occurredAt: occurredAt, kind: kind)
    }

    private func integer(_ value: String?) -> Int? { value.flatMap(Int.init) }

    private func commaSeparatedIntegers(_ value: String?) -> [Int] {
        guard let value else { return [] }
        return value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func developmentAttempts(_ object: [String: JSONValue]?) -> [Bool] {
        if let values = object?["api_get_items"]?.arrayValue, !values.isEmpty {
            return values.map { value in
                guard let item = value.objectValue else { return false }
                return (item.int("api_id") ?? item.int("api_slotitem_id") ?? -1) > 0
            }
        }
        if let items = object?["api_slot_item"]?.arrayValue, !items.isEmpty {
            return items.map { value in
                guard let item = value.objectValue else { return false }
                return (item.int("api_id") ?? item.int("api_slotitem_id") ?? -1) > 0
            }
        }
        if let created = object?.int("api_create_flag") { return [created == 1] }
        if let item = object?["api_slot_item"]?.objectValue {
            return [(item.int("api_id") ?? item.int("api_slotitem_id") ?? -1) > 0]
        }
        // A successful API call is one development attempt even when the game omits
        // result details (the Android tracker counts both successful and failed rolls).
        return [false]
    }
}
