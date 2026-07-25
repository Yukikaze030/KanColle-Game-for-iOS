import Foundation

/// Reset category used by Kcanotify's `quest_track.json` (`type`).
public enum QuestResetKind: Int, Codable, Sendable, Equatable, CaseIterable {
    case none = 0
    case daily = 1
    case weekly = 2
    case monthly = 3
    case quarterly = 5
}

public enum QuestTrackingPrecision: String, Codable, Sendable, Equatable {
    case exact
    case serverOnly
}

public struct QuestDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let resetKind: QuestResetKind
    public let conditionTargets: [Int]
    public let code: String?
    public let title: String?
    public let detail: String?

    public init(
        id: Int,
        resetKind: QuestResetKind,
        conditionTargets: [Int],
        code: String? = nil,
        title: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.resetKind = resetKind
        self.conditionTargets = conditionTargets
        self.code = code
        self.title = title
        self.detail = detail
    }
}

public struct QuestListItem: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let category: Int
    public let type: Int
    public var state: Int
    public var serverProgressFlag: Int
    public let title: String
    public let detail: String
    public let precision: QuestTrackingPrecision

    public init(
        id: Int,
        category: Int,
        type: Int,
        state: Int,
        serverProgressFlag: Int,
        title: String,
        detail: String,
        precision: QuestTrackingPrecision
    ) {
        self.id = id
        self.category = category
        self.type = type
        self.state = state
        self.serverProgressFlag = serverProgressFlag
        self.title = title
        self.detail = detail
        self.precision = precision
    }

    /// Coarse progress supplied by the game. Exact counters, when available, remain separate.
    public var serverProgressPercent: Int {
        if state == 3 { return 100 }
        switch serverProgressFlag {
        case 1: return 50
        case 2: return 80
        default: return 0
        }
    }
}

public struct QuestTrackingState: Codable, Sendable, Equatable {
    public let questID: Int
    public var isActive: Bool
    public var counters: [Int]
    public var startedAt: Date
    public let precision: QuestTrackingPrecision

    public init(
        questID: Int,
        isActive: Bool,
        counters: [Int],
        startedAt: Date,
        precision: QuestTrackingPrecision
    ) {
        self.questID = questID
        self.isActive = isActive
        self.counters = counters
        self.startedAt = startedAt
        self.precision = precision
    }
}

public struct CompletedQuest: Codable, Sendable, Equatable, Identifiable {
    public let questID: Int
    public let completedAt: Date
    public var id: String { "\(questID)@\(completedAt.timeIntervalSince1970)" }

    public init(questID: Int, completedAt: Date) {
        self.questID = questID
        self.completedAt = completedAt
    }
}

public struct QuestListSnapshot: Codable, Sendable, Equatable {
    public var items: [Int: QuestListItem]
    public var tracking: [Int: QuestTrackingState]
    public var completed: [CompletedQuest]
    public var updatedAt: Date?

    public init(
        items: [Int: QuestListItem] = [:],
        tracking: [Int: QuestTrackingState] = [:],
        completed: [CompletedQuest] = [],
        updatedAt: Date? = nil
    ) {
        self.items = items
        self.tracking = tracking
        self.completed = completed
        self.updatedAt = updatedAt
    }

    public var sortedItems: [QuestListItem] { items.values.sorted { $0.id < $1.id } }
}

public enum QuestDefinitionStoreError: Error, Sendable, Equatable {
    case invalidJSON
    case invalidTrackDefinition(id: String)
    case invalidQuestList
    case questNotFound(Int)
}
