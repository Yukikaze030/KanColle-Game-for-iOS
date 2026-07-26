import Foundation

/// Coarse groups deliberately mirror the ordering branches in
/// `KcaBattle.processData`. A plan is selected from the endpoint, never from the
/// order of keys in the JSON object.
public enum BattlePhasePlanStep: String, Codable, Sendable {
    case night
    case air
    case support
    case openingAntiSubmarine
    case openingTorpedo
    case shelling
    case closingTorpedo
}

public struct BattleEndpointPhasePlan: Equatable, Sendable {
    public let steps: [BattlePhasePlanStep]

    public init(steps: [BattlePhasePlanStep]) {
        self.steps = steps
    }

    public static func plan(for endpoint: BattleEndpoint) -> Self? {
        let standardDay: [BattlePhasePlanStep] = [
            .air, .support, .openingAntiSubmarine, .openingTorpedo, .shelling, .closingTorpedo
        ]
        let airOnly: [BattlePhasePlanStep] = [.air]
        let radar: [BattlePhasePlanStep] = [.air, .shelling]
        let night: [BattlePhasePlanStep] = [.night]

        switch endpoint.known {
        case .sortieBattle, .practiceBattle,
             .combinedBattle, .combinedWater, .enemyCombinedBattle,
             .eachBattle, .eachWater:
            return .init(steps: standardDay)
        case .sortieAirBattle, .combinedAirBattle:
            return .init(steps: airOnly)
        case .sortieLandAirBattle, .combinedLandAirBattle:
            return .init(steps: airOnly)
        case .sortieLandShooting, .combinedLandShooting:
            return .init(steps: radar)
        case .sortieNightToDay, .enemyCombinedNightToDay:
            return .init(steps: night + standardDay)
        case .midnightBattle, .specialMidnight, .practiceMidnight,
             .combinedMidnight, .combinedSpecialMidnight, .enemyCombinedMidnight:
            return .init(steps: night)
        default:
            return nil
        }
    }
}

public struct BattleHPFrame: Equatable, Sendable {
    public let friendlyMain: [Int]
    public let friendlyEscort: [Int]
    public let enemyMain: [Int]
    public let enemyEscort: [Int]

    public init(snapshot: BattleSnapshot) {
        friendlyMain = snapshot.friendlyMain.ships.map(\.currentHP)
        friendlyEscort = snapshot.friendlyEscort?.ships.map(\.currentHP) ?? []
        enemyMain = snapshot.enemyMain.ships.map(\.currentHP)
        enemyEscort = snapshot.enemyEscort?.ships.map(\.currentHP) ?? []
    }
}

public struct BattlePhaseTransition: Equatable, Sendable {
    public let phase: BattlePhaseResult
    public let before: BattleHPFrame
    public let after: BattleHPFrame
}

public enum BattleSessionReduction: Equatable, Sendable {
    case started(snapshot: BattleSnapshot, transitions: [BattlePhaseTransition])
    case continued(snapshot: BattleSnapshot, transitions: [BattlePhaseTransition])
    case completed(snapshot: BattleSnapshot)
    case duplicate(eventID: String)
    case rejected(endpoint: String, warnings: [BattleParseWarning])
    case ignored(endpoint: String)
}

/// Stateful reducer for one active battle. Response-level event IDs are the
/// idempotency boundary: every accepted API response advances revision exactly
/// once, regardless of how many damage phases it contains.
public struct BattleSessionReducer: Sendable {
    public private(set) var snapshot: BattleSnapshot?
    public private(set) var lastClosedSession: BattleSnapshot?
    public private(set) var transitions: [BattlePhaseTransition]

    private let decoder: BattlePhaseDecoder
    private let damageEngine: DamageEngine
    private var appliedResponseIDs: Set<String>
    private var revision: Int64

    public init(
        snapshot: BattleSnapshot? = nil,
        decoder: BattlePhaseDecoder = BattlePhaseDecoder(),
        damageEngine: DamageEngine = DamageEngine(),
        initialRevision: Int64? = nil
    ) {
        self.snapshot = snapshot
        self.decoder = decoder
        self.damageEngine = damageEngine
        transitions = []
        appliedResponseIDs = []
        revision = max(snapshot?.revision ?? 0, initialRevision ?? 0)
    }

    @discardableResult
    public mutating func reduce(
        envelope: APIEnvelope,
        eventID: String? = nil,
        friendlyMainShipIDs: [Int] = [],
        friendlyEscortShipIDs: [Int] = [],
        map: BattleMapPosition? = nil,
        fleetSnapshot: FleetSnapshot? = nil,
        sortieDeckID: Int? = nil
    ) -> BattleSessionReduction {
        if let eventID, appliedResponseIDs.contains(eventID) {
            return .duplicate(eventID: eventID)
        }

        let endpoint = BattleEndpoint(envelope.endpoint)
        guard envelope.apiResult == nil || envelope.apiResult == 1 else {
            return .rejected(endpoint: endpoint.path, warnings: [
                .init(field: "api_result", message: envelope.apiResultMessage ?? "battle API failed")
            ])
        }

        if endpoint.isResult {
            guard var current = snapshot else {
                return outOfOrder(endpoint, expected: "active battle before result")
            }
            current.status = .completed
            advanceRevision(of: &current)
            snapshot = current
            remember(eventID)
            transitions = []
            return .completed(snapshot: current)
        }

        if endpoint.known == .sortieGoback || endpoint.known == .combinedGoback {
            guard var current = snapshot, current.status != .completed else {
                return outOfOrder(endpoint, expected: "active battle before retreat")
            }
            applyRetreat(data: envelope.data, to: &current)
            advanceRevision(of: &current)
            current.endpoint = endpoint
            snapshot = current
            transitions = []
            remember(eventID)
            return .continued(snapshot: current, transitions: [])
        }

        guard let data = envelope.data,
              let plan = BattleEndpointPhasePlan.plan(for: endpoint) else {
            return .ignored(endpoint: endpoint.path)
        }

        if endpoint.continuesSession {
            guard var current = snapshot,
                  current.status != .completed else {
                return outOfOrder(endpoint, expected: "day battle before night continuation")
            }
            if endpoint.isPractice != (current.kind == .practice) {
                return outOfOrder(endpoint, expected: "matching sortie/practice battle")
            }
            let applied = apply(data: data, endpoint: endpoint, plan: plan, to: &current)
            advanceRevision(of: &current)
            current.endpoint = endpoint
            snapshot = current
            transitions = applied
            remember(eventID)
            return .continued(snapshot: current, transitions: applied)
        }

        guard endpoint.initializesSession else {
            return .ignored(endpoint: endpoint.path)
        }

        let resolvedMainIDs = resolvedMainShipIDs(
            explicit: friendlyMainShipIDs,
            snapshot: fleetSnapshot,
            deckID: sortieDeckID ?? map?.deckID
        )
        let resolvedEscortIDs = resolvedEscortShipIDs(
            explicit: friendlyEscortShipIDs,
            endpoint: endpoint,
            snapshot: fleetSnapshot
        )
        guard var fresh = decoder.initializeSession(
            endpoint: endpoint,
            data: data,
            friendlyMainShipIDs: resolvedMainIDs,
            friendlyEscortShipIDs: resolvedEscortIDs,
            map: map,
            revision: revision &+ 1
        ) else {
            return .rejected(endpoint: endpoint.path, warnings: [
                .init(field: "initialization", message: "missing valid battle HP arrays")
            ])
        }
        if let fleetSnapshot {
            DameconResolver.freezeLoadout(in: &fresh, from: fleetSnapshot)
        }

        if var old = snapshot {
            old.status = .completed
            lastClosedSession = old
        }
        revision = fresh.revision
        let applied = apply(data: data, endpoint: endpoint, plan: plan, to: &fresh)
        snapshot = fresh
        transitions = applied
        remember(eventID)
        return .started(snapshot: fresh, transitions: applied)
    }

    private mutating func apply(
        data: JSONValue,
        endpoint: BattleEndpoint,
        plan: BattleEndpointPhasePlan,
        to snapshot: inout BattleSnapshot
    ) -> [BattlePhaseTransition] {
        let vector = decoder.decodeVectorPhases(from: data)
        let shelling = decoder.decodeShellingPhases(from: data, endpoint: endpoint)
        let groups: [BattlePhasePlanStep: [BattlePhaseResult]] = [
            .night: shelling.filter { $0.kind == .friendlyFleet || $0.kind == .night },
            .air: vector.filter { $0.kind == .airBase || $0.kind == .aerial },
            .support: vector.filter { $0.kind == .support },
            .openingAntiSubmarine: shelling.filter { $0.kind == .openingAntiSubmarine },
            .openingTorpedo: vector.filter { $0.kind == .openingTorpedo },
            .shelling: shelling.filter { $0.kind == .shelling },
            .closingTorpedo: vector.filter { $0.kind == .torpedo }
        ]

        var result: [BattlePhaseTransition] = []
        var localEventIDs: Set<String> = []
        for step in plan.steps {
            for phase in groups[step] ?? [] {
                let before = BattleHPFrame(snapshot: snapshot)
                let application = damageEngine.apply(
                    phase, to: &snapshot, appliedEventIDs: &localEventIDs
                )
                guard application.applied else { continue }
                let appliedPhase = snapshot.phases.last ?? phase
                snapshot.warnings.append(contentsOf: application.warnings)
                result.append(.init(
                    phase: appliedPhase,
                    before: before,
                    after: BattleHPFrame(snapshot: snapshot)
                ))
            }
        }
        return result
    }

    private mutating func advanceRevision(of snapshot: inout BattleSnapshot) {
        revision &+= 1
        snapshot.revision = revision
    }

    private mutating func remember(_ eventID: String?) {
        if let eventID { appliedResponseIDs.insert(eventID) }
    }

    private func resolvedMainShipIDs(
        explicit: [Int],
        snapshot: FleetSnapshot?,
        deckID: Int?
    ) -> [Int] {
        if !explicit.isEmpty { return explicit }
        guard let snapshot, let deckID else { return [] }
        return snapshot.decks[deckID]?.shipIDs ?? []
    }

    private func resolvedEscortShipIDs(
        explicit: [Int],
        endpoint: BattleEndpoint,
        snapshot: FleetSnapshot?
    ) -> [Int] {
        if !explicit.isEmpty { return explicit }
        guard endpoint.usesFriendlyCombinedFleet,
              let snapshot, snapshot.combinedFleetType > 0 else { return [] }
        return snapshot.decks[2]?.shipIDs ?? []
    }

    private func applyRetreat(
        data: JSONValue?,
        to snapshot: inout BattleSnapshot
    ) {
        guard let object = data?.objectValue else {
            snapshot.warnings.append(.init(field: "goback_port", message: "missing retreat data"))
            return
        }
        let mainOrGlobal = object.intArray("api_escape_idx")
        let combinedLocal = object.intArray("api_escape_idx_combined")

        for rawIndex in mainOrGlobal {
            let position: BattleShipPosition
            if rawIndex > 6 {
                position = .init(component: .escort, index: rawIndex - 7)
            } else {
                position = .init(component: .main, index: rawIndex - 1)
            }
            markEscaped(position, in: &snapshot)
        }
        for rawIndex in combinedLocal {
            markEscaped(
                .init(component: .escort, index: rawIndex - 1),
                in: &snapshot
            )
        }
    }

    private func markEscaped(
        _ position: BattleShipPosition,
        in snapshot: inout BattleSnapshot
    ) {
        guard position.index >= 0 else {
            snapshot.warnings.append(.init(field: "goback_port", message: "invalid retreat index"))
            return
        }
        switch position.component {
        case .main:
            guard snapshot.friendlyMain.ships.indices.contains(position.index) else {
                snapshot.warnings.append(.init(
                    field: "goback_port",
                    message: "retreat target out of range: main.\(position.index)"
                ))
                return
            }
            snapshot.friendlyMain.ships[position.index].escaped = true
        case .escort:
            guard snapshot.friendlyEscort?.ships.indices.contains(position.index) == true else {
                snapshot.warnings.append(.init(
                    field: "goback_port",
                    message: "retreat target out of range: escort.\(position.index)"
                ))
                return
            }
            snapshot.friendlyEscort!.ships[position.index].escaped = true
        }
    }

    private func outOfOrder(
        _ endpoint: BattleEndpoint,
        expected: String
    ) -> BattleSessionReduction {
        .rejected(endpoint: endpoint.path, warnings: [
            .init(field: "endpoint", message: "out-of-order endpoint; expected \(expected)")
        ])
    }
}
