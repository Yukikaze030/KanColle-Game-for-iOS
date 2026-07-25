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

    func clearSessionPresentation() {
        isRestored = false
        isStale = false
        lastError = nil
    }
}
