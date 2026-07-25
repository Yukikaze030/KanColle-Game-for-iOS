import Foundation

public struct BattlePhaseDecoder: Sendable {
    public init() {}

    public func initializeSession(
        endpoint: BattleEndpoint,
        data: JSONValue,
        friendlyMainShipIDs: [Int] = [],
        friendlyEscortShipIDs: [Int] = [],
        map: BattleMapPosition? = nil,
        revision: Int64 = 1
    ) -> BattleSnapshot? {
        guard endpoint.initializesSession, let object = data.objectValue else { return nil }
        var warnings: [BattleParseWarning] = []

        let friendlyMain = fleet(
            maximum: object["api_f_maxhps"],
            current: object["api_f_nowhps"],
            masterIDs: nil,
            levels: nil,
            userIDs: friendlyMainShipIDs,
            component: .main,
            friendly: true,
            field: "api_f_nowhps",
            warnings: &warnings
        )
        let enemyMain = fleet(
            maximum: object["api_e_maxhps"],
            current: object["api_e_nowhps"],
            masterIDs: object["api_ship_ke"],
            levels: object["api_ship_lv"],
            userIDs: [],
            component: .main,
            friendly: false,
            field: "api_e_nowhps",
            warnings: &warnings
        )
        guard !friendlyMain.ships.isEmpty, !enemyMain.ships.isEmpty else {
            return nil
        }

        let friendlyEscort = optionalFleet(
            maximum: object["api_f_maxhps_combined"],
            current: object["api_f_nowhps_combined"],
            masterIDs: nil,
            levels: nil,
            userIDs: friendlyEscortShipIDs,
            component: .escort,
            friendly: true,
            field: "api_f_nowhps_combined",
            warnings: &warnings
        )
        let enemyEscort = optionalFleet(
            maximum: object["api_e_maxhps_combined"],
            current: object["api_e_nowhps_combined"],
            masterIDs: object["api_ship_ke_combined"],
            levels: object["api_ship_lv_combined"],
            userIDs: [],
            component: .escort,
            friendly: false,
            field: "api_e_nowhps_combined",
            warnings: &warnings
        )

        return BattleSnapshot(
            sessionID: UUID(),
            endpoint: endpoint,
            kind: endpoint.isPractice ? .practice : .sortie,
            map: map,
            formation: formation(object["api_formation"]),
            friendlyMain: friendlyMain,
            friendlyEscort: friendlyEscort,
            enemyMain: enemyMain,
            enemyEscort: enemyEscort,
            phases: [.init(kind: .initialization)],
            status: .active,
            warnings: warnings,
            revision: max(1, revision)
        )
    }

    public func mapPosition(from envelope: APIEnvelope) -> BattleMapPosition? {
        let endpoint = BattleEndpoint(envelope.endpoint)
        guard endpoint.known == .mapStart || endpoint.known == .mapNext,
              let object = envelope.data?.objectValue else { return nil }
        return BattleMapPosition(
            deckID: envelope.requestParameters["api_deck_id"].flatMap(Int.init),
            mapAreaID: envelope.requestParameters["api_maparea_id"].flatMap(Int.init),
            mapNumber: envelope.requestParameters["api_mapinfo_no"].flatMap(Int.init),
            nodeID: object.int("api_no"),
            eventID: object.int("api_event_id"),
            eventKind: object.int("api_event_kind"),
            isBoss: object.int("api_bosscell_no") == object.int("api_no")
        )
    }

    /// Decodes vector-shaped battle phases in KcaBattle.processData order.
    public func decodeVectorPhases(from data: JSONValue) -> [BattlePhaseResult] {
        guard let object = data.objectValue else { return [] }
        var phases: [BattlePhaseResult] = []
        appendAir(object["api_air_base_injection"], kind: .airBase, to: &phases)
        appendAir(object["api_injection_kouku"], kind: .aerial, to: &phases)
        if let attacks = object["api_air_base_attack"]?.arrayValue {
            for attack in attacks {
                appendAir(attack, kind: .airBase, to: &phases)
            }
        }
        appendAir(object["api_kouku"], kind: .aerial, to: &phases)
        appendAir(object["api_kouku2"], kind: .aerial, to: &phases)
        appendSupport(object["api_support_info"], to: &phases)
        appendTorpedo(object["api_opening_atack"], kind: .openingTorpedo, to: &phases)
        appendTorpedo(object["api_raigeki"], kind: .torpedo, to: &phases)
        return phases
    }

    private func appendAir(
        _ value: JSONValue?,
        kind: BattlePhaseKind,
        to phases: inout [BattlePhaseResult]
    ) {
        guard let object = value?.objectValue else { return }
        var warnings: [BattleParseWarning] = []
        var events: [DamageEvent] = []
        if let stage = object["api_stage3"]?.objectValue {
            events += vectorEvents(stage["api_fdam"], friendly: true, combinedOnly: false, field: "api_fdam", warnings: &warnings)
            events += vectorEvents(stage["api_edam"], friendly: false, combinedOnly: false, field: "api_edam", warnings: &warnings)
        }
        if let stage = object["api_stage3_combined"]?.objectValue {
            events += vectorEvents(stage["api_fdam"], friendly: true, combinedOnly: true, field: "api_fdam_combined", warnings: &warnings)
            events += vectorEvents(stage["api_edam"], friendly: false, combinedOnly: true, field: "api_edam_combined", warnings: &warnings)
        }
        if !events.isEmpty || !warnings.isEmpty {
            phases.append(.init(kind: kind, events: events, warnings: warnings))
        }
    }

    private func appendSupport(_ value: JSONValue?, to phases: inout [BattlePhaseResult]) {
        guard let object = value?.objectValue else { return }
        let damage = object["api_support_airatack"]?.objectValue?["api_stage3"]?.objectValue?["api_edam"]
            ?? object["api_support_hourai"]?.objectValue?["api_damage"]
        var warnings: [BattleParseWarning] = []
        let events = vectorEvents(
            damage, friendly: false, combinedOnly: false,
            field: "api_support_damage", warnings: &warnings
        )
        if !events.isEmpty || !warnings.isEmpty {
            phases.append(.init(kind: .support, events: events, warnings: warnings))
        }
    }

    private func appendTorpedo(
        _ value: JSONValue?,
        kind: BattlePhaseKind,
        to phases: inout [BattlePhaseResult]
    ) {
        guard let object = value?.objectValue else { return }
        var warnings: [BattleParseWarning] = []
        let events = vectorEvents(
            object["api_fdam"], friendly: true, combinedOnly: false,
            field: "api_fdam", warnings: &warnings
        ) + vectorEvents(
            object["api_edam"], friendly: false, combinedOnly: false,
            field: "api_edam", warnings: &warnings
        )
        if !events.isEmpty || !warnings.isEmpty {
            phases.append(.init(kind: kind, events: events, warnings: warnings))
        }
    }

    private func vectorEvents(
        _ value: JSONValue?,
        friendly: Bool,
        combinedOnly: Bool,
        field: String,
        warnings: inout [BattleParseWarning]
    ) -> [DamageEvent] {
        guard let values = value?.arrayValue else { return [] }
        return values.enumerated().compactMap { offset, value in
            guard let damage = battleDamage(value) else {
                if value != .null {
                    warnings.append(.init(field: field, message: "invalid damage at index \(offset)"))
                }
                return nil
            }
            guard damage > 0 else { return nil }
            let component: BattleFleetComponent
            let index: Int
            if combinedOnly {
                component = .escort
                index = offset
            } else if offset >= 6 {
                component = .escort
                index = offset - 6
            } else {
                component = .main
                index = offset
            }
            return DamageEvent(
                target: .init(component: component, index: index),
                targetIsFriendly: friendly,
                damage: damage
            )
        }
    }

    /// Matches Java Float.intValue(): finite floating damage truncates toward zero.
    private func battleDamage(_ value: JSONValue) -> Int? {
        switch value {
        case .integer(let number): return Int(exactly: number)
        case .number(let number) where number.isFinite: return Int(number)
        case .string(let text):
            guard let number = Double(text), number.isFinite else { return nil }
            return Int(number)
        default: return nil
        }
    }

    private func optionalFleet(
        maximum: JSONValue?,
        current: JSONValue?,
        masterIDs: JSONValue?,
        levels: JSONValue?,
        userIDs: [Int],
        component: BattleFleetComponent,
        friendly: Bool,
        field: String,
        warnings: inout [BattleParseWarning]
    ) -> BattleFleetState? {
        guard maximum != nil || current != nil else { return nil }
        let result = fleet(
            maximum: maximum, current: current, masterIDs: masterIDs, levels: levels,
            userIDs: userIDs, component: component, friendly: friendly,
            field: field, warnings: &warnings
        )
        return result.ships.isEmpty ? nil : result
    }

    private func fleet(
        maximum: JSONValue?,
        current: JSONValue?,
        masterIDs: JSONValue?,
        levels: JSONValue?,
        userIDs: [Int],
        component: BattleFleetComponent,
        friendly: Bool,
        field: String,
        warnings: inout [BattleParseWarning]
    ) -> BattleFleetState {
        let maximumValues = normalized(maximum, field: field.replacingOccurrences(of: "now", with: "max"), warnings: &warnings)
        let currentValues = normalized(current, field: field, warnings: &warnings)
        let masterValues = normalized(masterIDs, field: "ship ids", warnings: &warnings, removeDummyOnlyWhenSeven: true)
        let levelValues = normalized(levels, field: "ship levels", warnings: &warnings, removeDummyOnlyWhenSeven: true)
        if maximumValues.count != currentValues.count {
            warnings.append(.init(field: field, message: "HP array lengths differ"))
        }

        let count = min(6, min(maximumValues.count, currentValues.count))
        var ships: [BattleShipState] = []
        for index in 0..<count {
            guard let maxHP = maximumValues[index], let nowHP = currentValues[index],
                  maxHP > 0, nowHP >= 0 else {
                warnings.append(.init(field: field, message: "invalid HP at index \(index)"))
                continue
            }
            let position = BattleShipPosition(component: component, index: index)
            let masterID = index < masterValues.count ? masterValues[index] : nil
            let identity: BattleShipIdentity
            if friendly, index < userIDs.count, userIDs[index] > 0 {
                identity = .friendlyUserShip(userIDs[index])
            } else if friendly {
                identity = .friendlyUserShip(-(component == .main ? index + 1 : index + 101))
            } else {
                identity = .enemyMasterShip(masterID: masterID, position: position)
            }
            ships.append(BattleShipState(
                id: identity,
                position: position,
                masterShipID: friendly ? nil : masterID,
                level: index < levelValues.count ? levelValues[index] : nil,
                maximumHP: maxHP,
                initialHP: min(maxHP, nowHP),
                currentHP: min(maxHP, nowHP)
            ))
        }
        if max(maximumValues.count, currentValues.count) > 6 {
            warnings.append(.init(field: field, message: "fleet truncated to 6 ships"))
        }
        return BattleFleetState(ships: ships)
    }

    private func normalized(
        _ value: JSONValue?,
        field: String,
        warnings: inout [BattleParseWarning],
        removeDummyOnlyWhenSeven: Bool = false
    ) -> [Int?] {
        guard let array = value?.arrayValue else { return [] }
        var values = array.map { element -> Int? in
            if let number = element.intValue { return number }
            if element != .null {
                warnings.append(.init(field: field, message: "non-integer value ignored"))
            }
            return nil
        }
        if let first = values.first, (first ?? -1) <= 0,
           (!removeDummyOnlyWhenSeven || values.count == 7) {
            values.removeFirst()
        }
        return values
    }

    private func formation(_ value: JSONValue?) -> BattleFormation? {
        guard let values = value?.arrayValue?.compactMap(\.intValue), values.count >= 3 else {
            return nil
        }
        return BattleFormation(friendly: values[0], enemy: values[1], engagement: values[2])
    }
}
