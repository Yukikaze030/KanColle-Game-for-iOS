import Foundation

public enum QuestProgressReduction: Sendable, Equatable {
    case applied(questIDs: [Int])
    case duplicate(eventID: String)
    case ignored
}

/// Applies basic count-only quest rules. Map, rank, enemy composition and fleet
/// predicates intentionally belong to the task-10 condition evaluator.
public struct QuestProgressReducer: Sendable {
    public struct CounterRule: Sendable, Equatable {
        public let questID: Int
        public let conditionIndex: Int
        public let amount: Int

        public init(questID: Int, conditionIndex: Int = 0, amount: Int = 1) {
            self.questID = questID
            self.conditionIndex = conditionIndex
            self.amount = amount
        }
    }

    private let definitions: [Int: QuestDefinition]
    private let resetCalendar: QuestResetCalendar
    private let deduplicationCapacity: Int
    private var recentEventIDs: [String] = []
    private var recentEventIDSet: Set<String> = []

    public init(
        definitions: [Int: QuestDefinition],
        resetCalendar: QuestResetCalendar = QuestResetCalendar(),
        deduplicationCapacity: Int = 128
    ) {
        self.definitions = definitions
        self.resetCalendar = resetCalendar
        self.deduplicationCapacity = max(1, deduplicationCapacity)
    }

    @discardableResult
    public mutating func reduce(
        _ event: QuestEvent,
        snapshot: inout QuestListSnapshot
    ) -> QuestProgressReduction {
        guard !recentEventIDSet.contains(event.id) else { return .duplicate(eventID: event.id) }
        remember(event.id)

        let rules = Self.rules(for: event.kind)
        guard !rules.isEmpty else { return .ignored }
        var changed = Set<Int>()
        for rule in rules where apply(rule, at: event.occurredAt, snapshot: &snapshot) {
            changed.insert(rule.questID)
        }
        guard !changed.isEmpty else { return .ignored }
        snapshot.updatedAt = event.occurredAt
        return .applied(questIDs: changed.sorted())
    }

    public mutating func resetDeduplication() {
        recentEventIDs.removeAll(keepingCapacity: true)
        recentEventIDSet.removeAll(keepingCapacity: true)
    }

    /// Explicit port of `KcaService.updateIdCountTracker` call sites. The table keeps
    /// condition indices visible and reviewable instead of hiding them in URL branches.
    public static func rules(for event: QuestEvent.Kind) -> [CounterRule] {
        switch event {
        case let .expeditionFinished(missionID, succeeded):
            guard succeeded else { return [] }
            var rules = [402, 403, 404].map { CounterRule(questID: $0) }
            switch missionID {
            case 3: rules.append(CounterRule(questID: 426, conditionIndex: 0))
            case 4:
                rules.append(CounterRule(questID: 426, conditionIndex: 1))
                rules.append(CounterRule(questID: 428, conditionIndex: 0))
            case 5:
                rules.append(CounterRule(questID: 424))
                rules.append(CounterRule(questID: 426, conditionIndex: 2))
            case 10: rules.append(CounterRule(questID: 426, conditionIndex: 3))
            case 37, 38:
                rules.append(CounterRule(questID: 410))
                rules.append(CounterRule(questID: 411))
            case 101: rules.append(CounterRule(questID: 428, conditionIndex: 1))
            case 102: rules.append(CounterRule(questID: 428, conditionIndex: 2))
            default: break
            }
            return rules
        case .dockingStarted:
            return [CounterRule(questID: 503)]
        case .supplied:
            return [CounterRule(questID: 504)]
        case let .itemDeveloped(attemptCount, _):
            let count = max(0, attemptCount)
            return count == 0 ? [] : [
                CounterRule(questID: 605, amount: count),
                CounterRule(questID: 607, amount: count)
            ]
        case .itemDiscarded:
            // Android increments quest 613 once per discard request, including a batch.
            return [CounterRule(questID: 613)]
        case .shipBuilt:
            return [CounterRule(questID: 606), CounterRule(questID: 608)]
        case let .shipDiscarded(shipIDs):
            let count = shipIDs.count
            return count == 0 ? [] : [CounterRule(questID: 609, amount: count)]
        case .equipmentImproved:
            // Improvement quests count attempts; `api_remodel_flag` only controls the result item.
            return [CounterRule(questID: 619), CounterRule(questID: 1166), CounterRule(questID: 1167)]
        case let .modernizationCompleted(succeeded):
            return succeeded ? [CounterRule(questID: 702), CounterRule(questID: 703)] : []
        default:
            return []
        }
    }

    private func apply(
        _ rule: CounterRule,
        at date: Date,
        snapshot: inout QuestListSnapshot
    ) -> Bool {
        guard let definition = definitions[rule.questID],
              rule.conditionIndex >= 0,
              rule.conditionIndex < definition.conditionTargets.count,
              definition.conditionTargets[rule.conditionIndex] > 0,
              var tracking = snapshot.tracking[rule.questID],
              tracking.isActive,
              tracking.precision == .exact,
              rule.conditionIndex < tracking.counters.count,
              !resetCalendar.isExpired(
                  startedAt: tracking.startedAt,
                  now: date,
                  questID: rule.questID,
                  resetKind: definition.resetKind
              ) else { return false }

        let target = definition.conditionTargets[rule.conditionIndex]
        let current = max(0, tracking.counters[rule.conditionIndex])
        let increment = max(0, rule.amount)
        let addition = current.addingReportingOverflow(increment)
        let next = min(target, addition.overflow ? Int.max : addition.partialValue)
        guard next != current else { return false }
        tracking.counters[rule.conditionIndex] = next
        snapshot.tracking[rule.questID] = tracking
        return true
    }

    private mutating func remember(_ eventID: String) {
        guard recentEventIDSet.insert(eventID).inserted else { return }
        recentEventIDs.append(eventID)
        if recentEventIDs.count > deduplicationCapacity {
            recentEventIDSet.remove(recentEventIDs.removeFirst())
        }
    }
}
