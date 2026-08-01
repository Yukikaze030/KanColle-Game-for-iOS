import Foundation
import Observation
import GameCore

@MainActor
@Observable
final class GameStateModel {
    private(set) var state = GameDataState(
        master: GameMasterData(),
        fleet: FleetSnapshot()
    )
    private(set) var timers: [GameTimer] = []
    private(set) var isRestored = false
    private(set) var isStale = false
    private(set) var lastError: String?
    private(set) var battle: BattleSnapshot?
    /// A battle that was active when the app stopped. It is intentionally kept
    /// out of `battle` so the live HUD never treats stale HP as current state.
    private(set) var interruptedBattle: BattleSnapshot?
    private(set) var battleResult: BattleResultMerge?
    private(set) var battleLogs: [BattleLogEntry] = []
    private(set) var quests = QuestListSnapshot()
    private(set) var questDefinitions: [Int: QuestDefinition] = [:]
    private(set) var battleRevision: Int64 = 0
    private(set) var questRevision: Int64 = 0
    private(set) var p3RecoveryIssues: [P3RecoveryIssue] = []

    var hasFleetData: Bool { !state.fleet.decks.isEmpty }

    func publish(
        state: GameDataState,
        timers: [GameTimer],
        restored: Bool = false,
        stale: Bool = false
    ) {
        guard state.revision >= self.state.revision || !hasFleetData else { return }
        self.state = state
        self.timers = timers
        isRestored = restored
        isStale = stale
        lastError = nil
    }

    func report(_ message: String) {
        lastError = String(message.prefix(512))
    }

    func publishP3(
        battle: BattleSnapshot?,
        interruptedBattle: BattleSnapshot? = nil,
        battleResult: BattleResultMerge?,
        battleLogs: [BattleLogEntry],
        quests: QuestListSnapshot,
        questDefinitions: [Int: QuestDefinition] = [:],
        battleRevision: Int64,
        questRevision: Int64,
        recoveryIssues: [P3RecoveryIssue] = []
    ) {
        guard battleRevision >= self.battleRevision,
              questRevision >= self.questRevision else { return }
        self.battle = battle
        self.interruptedBattle = interruptedBattle
        self.battleResult = battleResult
        self.battleLogs = Array(battleLogs.prefix(BattleLogProjector.maximumEntries))
        self.quests = quests
        if !questDefinitions.isEmpty {
            self.questDefinitions = questDefinitions
        }
        self.battleRevision = battleRevision
        self.questRevision = questRevision
        self.p3RecoveryIssues = Array(recoveryIssues.prefix(20))
    }

    func publishCombined(
        state: GameDataState,
        timers: [GameTimer],
        battle: BattleSnapshot?,
        battleResult: BattleResultMerge?,
        battleLogs: [BattleLogEntry],
        quests: QuestListSnapshot,
        questDefinitions: [Int: QuestDefinition],
        battleRevision: Int64,
        questRevision: Int64
    ) {
        publish(state: state, timers: timers)
        publishP3(
            battle: battle,
            interruptedBattle: battle == nil ? self.interruptedBattle : nil,
            battleResult: battleResult,
            battleLogs: battleLogs,
            quests: quests,
            questDefinitions: questDefinitions,
            battleRevision: battleRevision,
            questRevision: questRevision
        )
    }

    func clearSessionPresentation() {
        isRestored = false
        isStale = false
        lastError = nil
        battle = nil
        interruptedBattle = nil
        battleResult = nil
        p3RecoveryIssues = []
    }
}
