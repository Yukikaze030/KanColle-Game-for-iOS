import Foundation

/// Kancolle reset calendar. Every calculation is pinned to Asia/Tokyo and is therefore
/// independent from the device time zone and daylight-saving rules elsewhere.
public struct QuestResetCalendar: Sendable {
    public static let tokyoTimeZone = TimeZone(identifier: "Asia/Tokyo")!
    public static let nonQuarterlyQuestIDs: Set<Int> = [211, 212]
    public static let longDailyPracticeQuestIDs: Set<Int> = [311, 318, 330, 337, 339, 342]

    private let calendar: Calendar

    public init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = Self.tokyoTimeZone
        calendar.firstWeekday = 2 // Monday
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
    }

    public func isExpired(
        startedAt: Date,
        now: Date,
        questID: Int,
        resetKind: QuestResetKind
    ) -> Bool {
        guard now >= startedAt else { return false }
        guard let start = periodStart(containing: now, questID: questID, resetKind: resetKind) else {
            return false
        }
        return startedAt < start
    }

    public func periodStart(
        containing date: Date,
        questID: Int,
        resetKind: QuestResetKind
    ) -> Date? {
        if Self.longDailyPracticeQuestIDs.contains(questID)
            || (resetKind == .quarterly && Self.nonQuarterlyQuestIDs.contains(questID)) {
            return startOfCalendarDay(containing: date)
        }

        switch resetKind {
        case .none:
            return nil
        case .daily:
            return mostRecentFiveAM(for: date)
        case .weekly:
            return weeklyStart(containing: date)
        case .monthly:
            return monthlyStart(containing: date)
        case .quarterly:
            return quarterlyStart(containing: date)
        }
    }

    public func nextReset(
        after date: Date,
        questID: Int,
        resetKind: QuestResetKind
    ) -> Date? {
        guard let start = periodStart(containing: date, questID: questID, resetKind: resetKind) else {
            return nil
        }
        let component: Calendar.Component
        let value: Int
        if Self.longDailyPracticeQuestIDs.contains(questID)
            || (resetKind == .quarterly && Self.nonQuarterlyQuestIDs.contains(questID)) {
            component = .day; value = 1
        } else {
            switch resetKind {
            case .none: return nil
            case .daily: component = .day; value = 1
            case .weekly: component = .day; value = 7
            case .monthly: component = .month; value = 1
            case .quarterly: component = .month; value = 3
            }
        }
        return calendar.date(byAdding: component, value: value, to: start)
    }

    private func startOfCalendarDay(containing date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func mostRecentFiveAM(for date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let todayReset = calendar.date(byAdding: .hour, value: 5, to: startOfDay)!
        if date >= todayReset { return todayReset }
        return calendar.date(byAdding: .day, value: -1, to: todayReset)!
    }

    private func weeklyStart(containing date: Date) -> Date {
        let dailyBoundary = mostRecentFiveAM(for: date)
        let weekday = calendar.component(.weekday, from: dailyBoundary)
        let daysSinceMonday = (weekday - 2 + 7) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: dailyBoundary)!
    }

    private func monthlyStart(containing date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        let thisMonth = calendar.date(from: DateComponents(
            timeZone: Self.tokyoTimeZone,
            year: components.year,
            month: components.month,
            day: 1,
            hour: 5
        ))!
        if date >= thisMonth { return thisMonth }
        return calendar.date(byAdding: .month, value: -1, to: thisMonth)!
    }

    private func quarterlyStart(containing date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year!
        let month = components.month!
        let boundaryMonth: Int
        let boundaryYear: Int
        if month < 3 {
            boundaryMonth = 12
            boundaryYear = year - 1
        } else {
            boundaryMonth = (month / 3) * 3
            boundaryYear = year
        }
        let candidate = calendar.date(from: DateComponents(
            timeZone: Self.tokyoTimeZone,
            year: boundaryYear,
            month: boundaryMonth,
            day: 1,
            hour: 5
        ))!
        if date >= candidate { return candidate }
        return calendar.date(byAdding: .month, value: -3, to: candidate)!
    }
}
