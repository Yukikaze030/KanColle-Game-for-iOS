import Foundation

/// A platform-neutral timer consumed by notifications, UI and widgets.
public struct GameTimer: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case expedition
        case docking
        case morale
        case akashi
    }

    public let id: String
    public let kind: Kind
    public let slot: Int?
    public let title: String
    public let detail: String
    public let completionDate: Date
    public let sourceRevision: Int64
    public let isCancelled: Bool

    public init(
        id: String,
        kind: Kind,
        slot: Int?,
        title: String,
        detail: String,
        completionDate: Date,
        sourceRevision: Int64,
        isCancelled: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.slot = slot
        self.title = title
        self.detail = detail
        self.completionDate = completionDate
        self.sourceRevision = sourceRevision
        self.isCancelled = isCancelled
    }
}

public struct ExpeditionTimerInput: Codable, Equatable, Sendable {
    public let fleetIndex: Int
    public let fleetName: String
    public let missionID: Int
    public let arrivalDate: Date?
    public let isActive: Bool

    public init(fleetIndex: Int, fleetName: String, missionID: Int, arrivalDate: Date?, isActive: Bool) {
        self.fleetIndex = fleetIndex
        self.fleetName = fleetName
        self.missionID = missionID
        self.arrivalDate = arrivalDate
        self.isActive = isActive
    }
}

public struct DockingTimerInput: Codable, Equatable, Sendable {
    public let dockIndex: Int
    public let state: Int
    public let shipID: Int
    public let shipName: String
    public let completionDate: Date?

    public init(dockIndex: Int, state: Int, shipID: Int, shipName: String, completionDate: Date?) {
        self.dockIndex = dockIndex
        self.state = state
        self.shipID = shipID
        self.shipName = shipName
        self.completionDate = completionDate
    }
}

public struct MoraleTimerInput: Codable, Equatable, Sendable {
    public let fleetIndex: Int
    public let fleetName: String
    public let condition: Int

    public init(fleetIndex: Int, fleetName: String, condition: Int) {
        self.fleetIndex = fleetIndex
        self.fleetName = fleetName
        self.condition = condition
    }
}

/// `formationSignature` must change whenever the Akashi flagship or repair formation changes.
public struct AkashiTimerInput: Codable, Equatable, Sendable {
    public let hasValidFlagship: Bool
    public let formationSignature: String
    public let detail: String

    public init(hasValidFlagship: Bool, formationSignature: String, detail: String = "泊地修理") {
        self.hasValidFlagship = hasValidFlagship
        self.formationSignature = formationSignature
        self.detail = detail
    }
}

public struct TimerProjectionInput: Codable, Equatable, Sendable {
    public let sourceRevision: Int64
    public let expeditions: [ExpeditionTimerInput]
    public let dockings: [DockingTimerInput]
    public let morales: [MoraleTimerInput]
    public let akashi: AkashiTimerInput?
    public let moraleThreshold: Int

    public init(
        sourceRevision: Int64,
        expeditions: [ExpeditionTimerInput] = [],
        dockings: [DockingTimerInput] = [],
        morales: [MoraleTimerInput] = [],
        akashi: AkashiTimerInput? = nil,
        moraleThreshold: Int = 40
    ) {
        self.sourceRevision = sourceRevision
        self.expeditions = expeditions
        self.dockings = dockings
        self.morales = morales
        self.akashi = akashi
        self.moraleThreshold = moraleThreshold
    }
}

public struct TimerProjection: Equatable, Sendable {
    public let timers: [GameTimer]
    public let added: [GameTimer]
    public let updated: [GameTimer]
    public let removed: [GameTimer]

    public init(timers: [GameTimer], added: [GameTimer], updated: [GameTimer], removed: [GameTimer]) {
        self.timers = timers
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}

/// Stateful projection preserving morale and Akashi registration times across API updates.
public struct TimerProjector {
    public static let moraleWaitUnit: TimeInterval = 179
    public static let akashiRepairInterval: TimeInterval = 20 * 60

    private struct MoraleRegistration {
        var condition: Int
        var registeredAt: Date
        var completionDate: Date
    }

    private struct AkashiRegistration {
        var signature: String
        var registeredAt: Date
    }

    private let clock: @Sendable () -> Date
    private var activeTimers: [String: GameTimer] = [:]
    private var moraleRegistrations: [Int: MoraleRegistration] = [:]
    private var akashiRegistration: AkashiRegistration?

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Lead time belongs to notification scheduling and never changes timer completion dates.
    public static func clampedNotificationLeadTime(_ seconds: TimeInterval) -> TimeInterval {
        min(600, max(0, seconds))
    }

    public mutating func project(_ input: TimerProjectionInput) -> TimerProjection {
        let now = clock()
        var next: [String: GameTimer] = [:]

        projectExpeditions(input.expeditions, revision: input.sourceRevision, into: &next)
        projectDockings(input.dockings, revision: input.sourceRevision, into: &next)
        projectMorales(
            input.morales,
            threshold: input.moraleThreshold,
            revision: input.sourceRevision,
            now: now,
            into: &next
        )
        projectAkashi(input.akashi, revision: input.sourceRevision, now: now, into: &next)

        let previous = activeTimers
        activeTimers = next

        let added = next.values.filter { previous[$0.id] == nil }
        let updated = next.values.filter { timer in
            guard let old = previous[timer.id] else { return false }
            return old != timer
        }
        let removed = previous.values.compactMap { timer -> GameTimer? in
            guard next[timer.id] == nil else { return nil }
            return GameTimer(
                id: timer.id,
                kind: timer.kind,
                slot: timer.slot,
                title: timer.title,
                detail: timer.detail,
                completionDate: timer.completionDate,
                sourceRevision: input.sourceRevision,
                isCancelled: true
            )
        }

        return TimerProjection(
            timers: Self.sorted(next.values),
            added: Self.sorted(added),
            updated: Self.sorted(updated),
            removed: Self.sorted(removed)
        )
    }

    private func projectExpeditions(
        _ inputs: [ExpeditionTimerInput],
        revision: Int64,
        into result: inout [String: GameTimer]
    ) {
        for input in inputs where (2...4).contains(input.fleetIndex) {
            guard input.isActive, input.missionID > 0, let arrivalDate = input.arrivalDate else { continue }
            let id = "expedition.\(input.fleetIndex)"
            result[id] = GameTimer(
                id: id,
                kind: .expedition,
                slot: input.fleetIndex,
                title: input.fleetName.isEmpty ? "第\(input.fleetIndex)舰队远征" : "\(input.fleetName)远征",
                detail: "远征 \(Self.expeditionLabel(input.missionID))",
                completionDate: arrivalDate,
                sourceRevision: revision
            )
        }
    }

    private func projectDockings(
        _ inputs: [DockingTimerInput],
        revision: Int64,
        into result: inout [String: GameTimer]
    ) {
        for input in inputs where input.dockIndex > 0 {
            guard input.state == 1, input.shipID > 0, let completionDate = input.completionDate else { continue }
            let id = "docking.\(input.dockIndex)"
            result[id] = GameTimer(
                id: id,
                kind: .docking,
                slot: input.dockIndex,
                title: "第\(input.dockIndex)入渠",
                detail: input.shipName.isEmpty ? "舰船 #\(input.shipID)" : input.shipName,
                completionDate: completionDate,
                sourceRevision: revision
            )
        }
    }

    private mutating func projectMorales(
        _ inputs: [MoraleTimerInput],
        threshold: Int,
        revision: Int64,
        now: Date,
        into result: inout [String: GameTimer]
    ) {
        let slots = Set(inputs.map(\.fleetIndex))
        moraleRegistrations = moraleRegistrations.filter { slots.contains($0.key) }

        for input in inputs where input.fleetIndex > 0 {
            guard input.condition < threshold else {
                moraleRegistrations[input.fleetIndex] = nil
                continue
            }

            let count = Int(ceil(Double(threshold - input.condition) / 3.0))
            let duration = TimeInterval(count) * Self.moraleWaitUnit
            var registration: MoraleRegistration

            if let old = moraleRegistrations[input.fleetIndex] {
                if input.condition < old.condition {
                    // Fatigue became worse: Android resets registered_time_check to the current confirmation.
                    registration = MoraleRegistration(
                        condition: input.condition,
                        registeredAt: now,
                        completionDate: now.addingTimeInterval(duration)
                    )
                } else {
                    let candidate = old.registeredAt.addingTimeInterval(duration)
                    registration = MoraleRegistration(
                        condition: input.condition,
                        registeredAt: old.registeredAt,
                        completionDate: min(old.completionDate, candidate)
                    )
                }
            } else {
                registration = MoraleRegistration(
                    condition: input.condition,
                    registeredAt: now,
                    completionDate: now.addingTimeInterval(duration)
                )
            }
            moraleRegistrations[input.fleetIndex] = registration

            let id = "morale.\(input.fleetIndex)"
            result[id] = GameTimer(
                id: id,
                kind: .morale,
                slot: input.fleetIndex,
                title: input.fleetName.isEmpty ? "第\(input.fleetIndex)舰队士气" : "\(input.fleetName)士气",
                detail: "cond \(input.condition) → \(threshold)",
                completionDate: registration.completionDate,
                sourceRevision: revision
            )
        }
    }

    private mutating func projectAkashi(
        _ input: AkashiTimerInput?,
        revision: Int64,
        now: Date,
        into result: inout [String: GameTimer]
    ) {
        guard let input, input.hasValidFlagship, !input.formationSignature.isEmpty else {
            akashiRegistration = nil
            return
        }

        if akashiRegistration?.signature != input.formationSignature {
            akashiRegistration = AkashiRegistration(signature: input.formationSignature, registeredAt: now)
        }
        guard let registration = akashiRegistration else { return }

        result["akashi"] = GameTimer(
            id: "akashi",
            kind: .akashi,
            slot: nil,
            title: "明石泊地修理",
            detail: input.detail,
            completionDate: registration.registeredAt.addingTimeInterval(Self.akashiRepairInterval),
            sourceRevision: revision
        )
    }

    private static func sorted<S: Sequence>(_ timers: S) -> [GameTimer] where S.Element == GameTimer {
        timers.sorted {
            if $0.completionDate != $1.completionDate { return $0.completionDate < $1.completionDate }
            return $0.id < $1.id
        }
    }

    private static func expeditionLabel(_ missionID: Int) -> String {
        guard missionID >= 100 else { return String(format: "%02d", missionID) }
        switch missionID {
        case 100..<110: return "A\(missionID + 1 - 100)"
        case 110..<120: return "B\(missionID + 1 - 110)"
        case 120..<130: return "C\(missionID + 1 - 120)"
        case 130..<140: return "D\(missionID - 130)"
        case 140..<150: return "E\(missionID - 140)"
        case 150..<160: return "F\(missionID - 150)"
        case 160..<170: return "G\(missionID - 160)"
        default: return missionID.isMultiple(of: 2) ? "S2" : "S1"
        }
    }
}
