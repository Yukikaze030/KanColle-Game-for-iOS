import Foundation

/// Platform-neutral projection used by the WidgetKit extension.
public struct WidgetTimerItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: GameTimer.Kind
    public let title: String
    public let detail: String
    public let completionDate: Date

    public init(
        id: String,
        kind: GameTimer.Kind,
        title: String,
        detail: String,
        completionDate: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.completionDate = completionDate
    }
}

public struct WidgetProjection: Equatable, Sendable {
    public let timers: [WidgetTimerItem]
    public let updatedAt: Date?
    public let isStale: Bool

    public init(timers: [WidgetTimerItem], updatedAt: Date?, isStale: Bool) {
        self.timers = timers
        self.updatedAt = updatedAt
        self.isStale = isStale
    }

    public static func make(
        timers: [GameTimer],
        updatedAt: Date?,
        now: Date,
        limit: Int = 4,
        staleAfter: TimeInterval = 6 * 60 * 60
    ) -> WidgetProjection {
        let visible = timers
            .filter { !$0.isCancelled && $0.completionDate > now }
            .sorted {
                if $0.completionDate != $1.completionDate {
                    return $0.completionDate < $1.completionDate
                }
                return $0.id < $1.id
            }
            .prefix(max(0, limit))
            .map {
                WidgetTimerItem(
                    id: $0.id,
                    kind: $0.kind,
                    title: $0.title,
                    detail: $0.detail,
                    completionDate: $0.completionDate
                )
            }

        let stale = updatedAt.map {
            now.timeIntervalSince($0) > max(0, staleAfter)
        } ?? false
        return WidgetProjection(timers: Array(visible), updatedAt: updatedAt, isStale: stale)
    }

    /// Refresh at the nearest completion, while ensuring the system is asked again
    /// at least every 15 minutes. WidgetKit may coalesce the actual reload.
    public func nextRefreshDate(now: Date, maximumInterval: TimeInterval = 15 * 60) -> Date {
        let fallback = now.addingTimeInterval(max(60, maximumInterval))
        guard let completion = timers.map(\.completionDate).min() else { return fallback }
        return min(max(completion, now.addingTimeInterval(1)), fallback)
    }
}
