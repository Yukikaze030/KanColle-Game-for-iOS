import Foundation

/// Pure notification reconciliation for projected game timers.
///
/// The planner deliberately has no dependency on `UserNotifications`, making capacity and
/// replacement behaviour deterministic and straightforward to test.
public struct NotificationPlanner: Sendable {
    public static let identifierPrefix = "p2.timer."

    public struct Settings: Equatable, Sendable {
        public var expeditionEnabled: Bool
        public var dockingEnabled: Bool
        public var moraleEnabled: Bool
        public var akashiEnabled: Bool
        public var leadTime: TimeInterval

        public init(
            expeditionEnabled: Bool = true,
            dockingEnabled: Bool = true,
            moraleEnabled: Bool = true,
            akashiEnabled: Bool = true,
            leadTime: TimeInterval = 61
        ) {
            self.expeditionEnabled = expeditionEnabled
            self.dockingEnabled = dockingEnabled
            self.moraleEnabled = moraleEnabled
            self.akashiEnabled = akashiEnabled
            self.leadTime = leadTime
        }

        fileprivate func isEnabled(_ kind: GameTimer.Kind) -> Bool {
            switch kind {
            case .expedition: expeditionEnabled
            case .docking: dockingEnabled
            case .morale: moraleEnabled
            case .akashi: akashiEnabled
            }
        }
    }

    public struct Request: Equatable, Sendable, Identifiable {
        public let id: String
        public let timerID: String
        public let kind: GameTimer.Kind
        public let title: String
        public let body: String
        public let fireDate: Date

        public init(
            id: String,
            timerID: String,
            kind: GameTimer.Kind,
            title: String,
            body: String,
            fireDate: Date
        ) {
            self.id = id
            self.timerID = timerID
            self.kind = kind
            self.title = title
            self.body = body
            self.fireDate = fireDate
        }
    }

    /// Metadata read from an existing platform notification request.
    public struct PendingRequest: Equatable, Sendable {
        public let id: String
        public let title: String
        public let body: String
        public let fireDate: Date

        public init(id: String, title: String, body: String, fireDate: Date) {
            self.id = id
            self.title = title
            self.body = body
            self.fireDate = fireDate
        }
    }

    public struct Plan: Equatable, Sendable {
        public let toAdd: [Request]
        public let toRemove: [String]

        public init(toAdd: [Request], toRemove: [String]) {
            self.toAdd = toAdd
            self.toRemove = toRemove
        }
    }

    public let systemLimit: Int
    public let safetyReserve: Int

    public init(systemLimit: Int = 64, safetyReserve: Int = 4) {
        self.systemLimit = max(0, systemLimit)
        self.safetyReserve = max(0, safetyReserve)
    }

    /// Reconciles when only pending identifiers are available. Existing P2 requests are
    /// conservatively replaced because their date/content cannot be compared safely.
    public func plan(
        timers: [GameTimer],
        pendingIdentifiers: Set<String>,
        foreignPendingCount: Int,
        settings: Settings,
        now: Date
    ) -> Plan {
        reconcile(
            timers: timers,
            pendingIdentifiers: pendingIdentifiers,
            comparablePending: [:],
            foreignPendingCount: foreignPendingCount,
            settings: settings,
            now: now
        )
    }

    /// Reconciles using full pending metadata, preserving requests that are already identical.
    public func plan(
        timers: [GameTimer],
        pendingRequests: [PendingRequest],
        foreignPendingCount: Int,
        settings: Settings,
        now: Date
    ) -> Plan {
        let byID = Dictionary(pendingRequests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return reconcile(
            timers: timers,
            pendingIdentifiers: Set(byID.keys),
            comparablePending: byID,
            foreignPendingCount: foreignPendingCount,
            settings: settings,
            now: now
        )
    }

    private func reconcile(
        timers: [GameTimer],
        pendingIdentifiers: Set<String>,
        comparablePending: [String: PendingRequest],
        foreignPendingCount: Int,
        settings: Settings,
        now: Date
    ) -> Plan {
        let leadTime = TimerProjector.clampedNotificationLeadTime(settings.leadTime)
        var nearestByIdentifier: [String: Request] = [:]

        for timer in timers where !timer.isCancelled && settings.isEnabled(timer.kind) {
            let fireDate = timer.completionDate.addingTimeInterval(-leadTime)
            guard fireDate > now else { continue }

            let identifier = Self.identifierPrefix + timer.id
            let request = Request(
                id: identifier,
                timerID: timer.id,
                kind: timer.kind,
                title: timer.title,
                body: timer.detail,
                fireDate: fireDate
            )
            if let existing = nearestByIdentifier[identifier], !Self.isEarlier(request, than: existing) {
                continue
            }
            nearestByIdentifier[identifier] = request
        }

        let availableP2Slots = max(0, systemLimit - safetyReserve - max(0, foreignPendingCount))
        let desired = nearestByIdentifier.values
            .sorted(by: Self.isEarlier)
            .prefix(availableP2Slots)
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })

        let currentP2 = pendingIdentifiers.filter { $0.hasPrefix(Self.identifierPrefix) }
        var removals = Set(currentP2.filter { desiredByID[$0] == nil })
        var additions: [Request] = []

        for request in desired.sorted(by: Self.isEarlier) {
            guard let pending = comparablePending[request.id] else {
                if pendingIdentifiers.contains(request.id) { removals.insert(request.id) }
                additions.append(request)
                continue
            }
            if pending.title != request.title || pending.body != request.body || pending.fireDate != request.fireDate {
                removals.insert(request.id)
                additions.append(request)
            }
        }

        return Plan(toAdd: additions, toRemove: removals.sorted())
    }

    private static func isEarlier(_ lhs: Request, than rhs: Request) -> Bool {
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        return lhs.id < rhs.id
    }
}
