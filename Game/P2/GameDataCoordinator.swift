import Foundation
import WidgetKit
import GameCore

actor GameDataCoordinator {
    private let parser = APIEnvelopeParser()
    private let pipeline = GameDataPipeline()
    private var projector = TimerProjector()
    private var battleReducer = BattleSessionReducer()
    private let battleDecoder = BattlePhaseDecoder()
    private let rankPredictor = BattleRankPredictor()
    private let resultMerger = BattleResultMerger()
    private let logProjector = BattleLogProjector()
    private let questRouter = QuestEventRouter()
    private let questDefinitions: QuestDefinitionStore?
    private var questReducer: QuestProgressReducer?
    private var questSnapshot = QuestListSnapshot()
    private var battleLogs: [BattleLogEntry] = []
    private var battleResult: BattleResultMerge?
    private var currentMap: BattleMapPosition?
    private var battleStartedAt: Date?
    private var questRevision: Int64 = 0
    private let model: GameStateModel
    private let store: GameSnapshotStore?
    private let p3Store: P3SnapshotStore?
    private let p3DatabaseURL: URL?
    private let notificationService: NotificationService
    private let settings: SettingsStore
    private let battleLogRetentionCount: Int
    private let exactQuestTrackingEnabled: Bool
    private var generation: UInt64 = 0

    init(
        model: GameStateModel,
        notificationService: NotificationService,
        settings: SettingsStore
    ) {
        self.model = model
        self.notificationService = notificationService
        self.settings = settings
        battleLogRetentionCount = settings.battleLogRetentionCount
        exactQuestTrackingEnabled = settings.exactQuestTrackingEnabled
        let definitions = Self.loadQuestDefinitions()
        questDefinitions = definitions
        questReducer = definitions.map { QuestProgressReducer(definitions: $0.definitions) }
        if let url = try? SharedContainer.snapshotDatabaseURL() {
            store = try? GameSnapshotStore(path: url.path)
        } else {
            store = nil
        }
        if let url = try? SharedContainer.p3DatabaseURL() {
            p3DatabaseURL = url
            p3Store = try? P3SnapshotStore(path: url.path)
        } else {
            p3DatabaseURL = nil
            p3Store = nil
        }
    }

    @discardableResult
    func startSession() async -> UInt64 {
        generation &+= 1
        let currentGeneration = generation
        await pipeline.reset()
        projector = TimerProjector()
        battleReducer = BattleSessionReducer()
        questReducer = questDefinitions.map { QuestProgressReducer(definitions: $0.definitions) }
        questSnapshot = QuestListSnapshot()
        battleLogs = []
        battleResult = nil
        currentMap = nil
        battleStartedAt = nil
        questRevision = 0

        do {
            if let restored: RestoredGameSnapshot<GameDataState> = try store?.restore(
                GameDataState.self,
                staleAfter: 6 * 60 * 60
            ) {
                guard currentGeneration == generation else { return currentGeneration }
                await pipeline.restore(restored.state)
                let timers = (try? store?.timers()) ?? []
                await model.publish(
                    state: restored.state,
                    timers: timers,
                    restored: true,
                    stale: restored.isStale
                )
                await notificationService.reconcile(
                    timers: timers,
                    plannerSettings: currentNotificationSettings
                )
            }
            if let restored = try p3Store?.restore() {
                guard currentGeneration == generation else { return currentGeneration }
                questSnapshot = restored.quests
                questRevision = restored.questRevision
                battleLogs = restored.battleLogs
                let restoredCurrentBattle = restored.currentBattle
                let restoredBattle = restoredCurrentBattle?.status == .restoredIncomplete
                    ? nil
                    : restoredCurrentBattle?.snapshot
                let interruptedBattle = restoredCurrentBattle?.status == .restoredIncomplete
                    ? restoredCurrentBattle?.snapshot
                    : nil
                battleReducer = BattleSessionReducer(
                    snapshot: restoredBattle,
                    initialRevision: restored.battleRevision
                )
                await model.publishP3(
                    battle: restoredBattle,
                    interruptedBattle: interruptedBattle,
                    battleResult: nil,
                    battleLogs: battleLogs,
                    quests: questSnapshot,
                    questDefinitions: questDefinitions?.definitions ?? [:],
                    battleRevision: restored.battleRevision,
                    questRevision: questRevision,
                    recoveryIssues: restored.recoveryIssues
                )
            }
        } catch {
            await model.report("快照恢复失败：\(error.localizedDescription)")
        }
        return currentGeneration
    }

    func stopSession() async {
        generation &+= 1
        await pipeline.reset()
        projector = TimerProjector()
        battleReducer = BattleSessionReducer()
        questReducer?.resetDeduplication()
        currentMap = nil
        battleStartedAt = nil
        battleResult = nil
        await model.clearSessionPresentation()
    }

    func ingest(
        endpoint: String,
        request: String?,
        response: String,
        session: UInt64
    ) async {
        guard session == generation else { return }
        let responseData = Data(response.utf8)
        let requestData = request.map { Data($0.utf8) }
        let eventID = Self.eventID(endpoint: endpoint, request: request, response: response)

        do {
            let envelope = try parser.parse(
                endpoint: endpoint,
                response: responseData,
                requestBody: requestData
            )
            let beforeState = await pipeline.state()
            let event = await pipeline.ingest(envelope: envelope, eventID: eventID)
            guard session == generation else { return }
            let state = await pipeline.state()
            let p2Changed = state.revision > beforeState.revision
            if case .incrementalUpdated(_, let warnings) = event, !warnings.isEmpty {
                await model.report(warnings.joined(separator: "；"))
            }

            let projection = projector.project(Self.timerInput(from: state))
            let p3Before = (battleReducer.snapshot?.revision ?? 0, questRevision)
            try reduceP3(
                envelope: envelope,
                eventID: eventID,
                occurredAt: Date(),
                fleetBefore: beforeState.fleet,
                master: state.master
            )
            let battleRevision = battleReducer.snapshot?.revision
                ?? battleLogs.first.map { _ in p3Before.0 } ?? 0
            let p3Changed = battleRevision != p3Before.0 || questRevision != p3Before.1
            // Publish live game data before attempting disk persistence. A full
            // disk or a damaged SQLite file must not hide valid API data, pause
            // battle/quest reduction, or suppress timer notifications.
            if p2Changed || p3Changed {
                await model.publishCombined(
                    state: state,
                    timers: projection.timers,
                    battle: battleReducer.snapshot,
                    battleResult: battleResult,
                    battleLogs: battleLogs,
                    quests: questSnapshot,
                    questDefinitions: questDefinitions?.definitions ?? [:],
                    battleRevision: battleRevision,
                    questRevision: questRevision
                )
            }
            if p2Changed {
                await notificationService.reconcile(
                    timers: projection.timers,
                    plannerSettings: currentNotificationSettings
                )
            }

            if p2Changed {
                persistP2(state: state, timers: projection.timers)
            }
            if p3Changed {
                persistP3(battleRevision: battleRevision)
            }
        } catch {
            let safeEndpoint = String(endpoint.prefix(160))
            await model.report("\(safeEndpoint)：\(error.localizedDescription)")
        }
    }

    /// Replans pending requests when a notification preference changes, without
    /// waiting for another game API response.
    func refreshNotifications() async {
        let state = await pipeline.state()
        let projection = projector.project(Self.timerInput(from: state))
        await notificationService.reconcile(
            timers: projection.timers,
            plannerSettings: currentNotificationSettings
        )
    }

    private var currentNotificationSettings: NotificationPlanner.Settings {
        .init(
            expeditionEnabled: settings.expeditionNotificationsEnabled,
            dockingEnabled: settings.dockingNotificationsEnabled,
            moraleEnabled: settings.moraleNotificationsEnabled,
            akashiEnabled: settings.akashiNotificationsEnabled,
            leadTime: TimeInterval(settings.notificationLeadTimeSeconds)
        )
    }

    /// Persistence is deliberately best-effort: it records diagnostics and
    /// leaves the in-memory presentation pipeline available for later APIs.
    private func persistP2(state: GameDataState, timers: [GameTimer]) {
        do {
            try store?.save(state: state, revision: state.revision, timers: timers)
            WidgetCenter.shared.reloadTimelines(ofKind: "GameTimersWidget")
        } catch {
            Task { @MainActor in
                DiagnosticsStore.shared.recordPersistenceFailure(store: "P2", error: error)
            }
        }
    }

    private func persistP3(battleRevision: Int64) {
        do {
            try p3Store?.save(
                quests: questSnapshot,
                questRevision: questRevision,
                currentBattle: battleReducer.snapshot,
                battleRevision: battleRevision,
                battleLogs: battleLogs
            )
            let databaseURL = p3DatabaseURL
            Task { @MainActor in
                DiagnosticsStore.shared.updateP3DatabaseSize(at: databaseURL)
            }
        } catch {
            Task { @MainActor in
                DiagnosticsStore.shared.recordPersistenceFailure(store: "P3", error: error)
            }
        }
    }

    private func reduceP3(
        envelope: APIEnvelope,
        eventID: String,
        occurredAt: Date,
        fleetBefore: FleetSnapshot,
        master: GameMasterData
    ) throws {
        if let map = battleDecoder.mapPosition(from: envelope) {
            currentMap = map
        }

        var questChanged = false
        if envelope.endpoint == "/api_get_member/questlist",
           let data = envelope.data,
           let questDefinitions {
            let synchronized = try questDefinitions.synchronize(
                apiData: data,
                previous: questSnapshot,
                at: occurredAt
            )
            questChanged = synchronized != questSnapshot
            questSnapshot = synchronized
        } else if let questDefinitions,
                  let questID = envelope.requestParameters["api_quest_id"].flatMap(Int.init) {
            let updated: QuestListSnapshot?
            switch envelope.endpoint {
            case "/api_req_quest/start":
                updated = try? questDefinitions.start(questID: questID, in: questSnapshot, at: occurredAt)
            case "/api_req_quest/stop":
                updated = try? questDefinitions.stop(questID: questID, in: questSnapshot, at: occurredAt)
            case "/api_req_quest/clearitemget":
                updated = try? questDefinitions.clear(questID: questID, in: questSnapshot, at: occurredAt)
            default:
                updated = nil
            }
            if let updated {
                questChanged = updated != questSnapshot
                questSnapshot = updated
            }
        }

        let deckID = currentMap?.deckID ?? envelope.requestParameters["api_deck_id"].flatMap(Int.init)
        let mainIDs = deckID.flatMap { fleetBefore.decks[$0]?.shipIDs } ?? []
        let escortIDs = fleetBefore.combinedFleetType > 0
            ? (fleetBefore.decks[2]?.shipIDs ?? [])
            : []
        let reduction = battleReducer.reduce(
            envelope: envelope,
            eventID: eventID,
            friendlyMainShipIDs: mainIDs,
            friendlyEscortShipIDs: escortIDs,
            map: currentMap,
            fleetSnapshot: fleetBefore,
            sortieDeckID: deckID
        )
        switch reduction {
        case .started(let snapshot, _):
            battleStartedAt = occurredAt
            battleResult = nil
            if let closed = battleReducer.lastClosedSession {
                archive(closed, at: occurredAt, master: master)
            }
            if snapshot.warnings.isEmpty == false {
                Task { @MainActor in
                    DiagnosticsStore.shared.recordP3Warnings(snapshot.warnings.count)
                }
            }
        case .continued(let snapshot, _):
            if snapshot.warnings.isEmpty == false {
                Task { @MainActor in
                    DiagnosticsStore.shared.recordP3Warnings(snapshot.warnings.count)
                }
            }
        case .completed(let snapshot):
            let prediction = rankPredictor.predict(rankInput(from: snapshot))
            battleResult = resultMerger.merge(data: envelope.data ?? .null, prediction: prediction)
            if battleResult?.diagnostics.isEmpty == false {
                Task { @MainActor in DiagnosticsStore.shared.recordRankMismatch() }
            }
            archive(snapshot, at: battleStartedAt ?? occurredAt, master: master)
        case .rejected(_, let warnings):
            if !warnings.isEmpty {
                Task { @MainActor in DiagnosticsStore.shared.recordP3Warnings(warnings.count) }
            }
        case .duplicate, .ignored:
            break
        }

        if exactQuestTrackingEnabled, let questReducer {
            var mutableReducer = questReducer
            for event in questRouter.routeAll(
                envelope: envelope,
                eventID: eventID,
                occurredAt: occurredAt
            ) {
                if case .applied = mutableReducer.reduce(event, snapshot: &questSnapshot) {
                    questChanged = true
                }
            }

            if let conditional = conditionalQuestEvent(
                envelope: envelope,
                battleReduction: reduction,
                fleetBefore: fleetBefore,
                master: master
            ) {
                let flags = QuestSessionFlags(
                    apDuplicationEnabled: questSnapshot.tracking[212]?.isActive == true
                        && questSnapshot.tracking[218]?.isActive == true
                )
                if case .applied = mutableReducer.reduce(
                    conditional,
                    eventID: eventID + "#conditional",
                    occurredAt: occurredAt,
                    flags: flags,
                    snapshot: &questSnapshot
                ) {
                    questChanged = true
                }
            }
            self.questReducer = mutableReducer
        }

        if questChanged { questRevision &+= 1 }
        let diagnosticEndpoint = envelope.endpoint
        let diagnosticBattleRevision = battleReducer.snapshot?.revision ?? 0
        let diagnosticQuestRevision = questRevision
        Task { @MainActor in
            DiagnosticsStore.shared.recordP3Endpoint(
                diagnosticEndpoint,
                battleRevision: diagnosticBattleRevision,
                questRevision: diagnosticQuestRevision
            )
        }
    }

    private func conditionalQuestEvent(
        envelope: APIEnvelope,
        battleReduction: BattleSessionReduction,
        fleetBefore: FleetSnapshot,
        master: GameMasterData
    ) -> QuestConditionalEvent? {
        if envelope.endpoint == "/api_req_map/start" || envelope.endpoint == "/api_req_map/next",
           let map = currentMap,
           let world = map.mapAreaID,
           let number = map.mapNumber,
           let node = map.nodeID {
            let deckID = map.deckID ?? envelope.requestParameters["api_deck_id"].flatMap(Int.init) ?? 1
            let ships = fleetBefore.ships(inDeck: deckID).enumerated().map { index, ship in
                QuestFleetShip(
                    masterShipID: ship.masterShipID,
                    shipType: master.ships[ship.masterShipID]?.shipTypeID,
                    position: .init(component: .main, index: index)
                )
            }
            return .nodeReached(.init(
                world: world,
                map: number,
                node: node,
                isStart: envelope.endpoint == "/api_req_map/start",
                deck: ships
            ))
        }
        guard case .completed(let snapshot) = battleReduction,
              let rank = battleResult?.server.rank ?? battleResult?.prediction?.rank else {
            return nil
        }
        let types = Dictionary(uniqueKeysWithValues: master.ships.map { ($0.key, $0.value.shipTypeID) })
        return .battleCompleted(.init(snapshot: snapshot, rank: rank, masterShipTypes: types))
    }

    private func archive(_ snapshot: BattleSnapshot, at date: Date, master: GameMasterData) {
        let enemyName = snapshot.enemyMain.ships.first?.masterShipID.flatMap { master.ships[$0]?.name }
        let damecon = snapshot.dameconActivations.isEmpty
            ? nil
            : "损管发动 \(snapshot.dameconActivations.count) 次"
        let entry = logProjector.project(
            snapshot: snapshot,
            startedAt: date,
            enemyFleetName: enemyName,
            prediction: battleResult?.prediction,
            serverResult: battleResult?.server,
            dameconSummary: damecon
        )
        battleLogs = logProjector.inserting(entry, into: battleLogs)
        battleLogs = Array(battleLogs.prefix(battleLogRetentionCount))
    }

    private func rankInput(from snapshot: BattleSnapshot) -> BattleRankInput {
        func fleet(_ state: BattleFleetState?) -> BattleRankFleetInput? {
            guard let state else { return nil }
            return .init(
                initialHP: state.ships.map { Optional($0.initialHP) },
                finalHP: state.ships.map { Optional($0.currentHP) },
                escaped: Set(state.ships.enumerated().compactMap { $0.element.escaped ? $0.offset : nil })
            )
        }
        return .init(
            friendlyMain: fleet(snapshot.friendlyMain)!,
            friendlyEscort: fleet(snapshot.friendlyEscort),
            enemyMain: fleet(snapshot.enemyMain)!,
            enemyEscort: fleet(snapshot.enemyEscort),
            isLandAirDefense: snapshot.endpoint.known == .sortieLandAirBattle
                || snapshot.endpoint.known == .combinedLandAirBattle,
            isPractice: snapshot.kind == .practice
        )
    }

    private static func loadQuestDefinitions() -> QuestDefinitionStore? {
        guard let track = bundleData(named: "quest_track", ext: "json") else { return nil }
        return try? QuestDefinitionStore(
            trackData: track,
            translationData: bundleData(named: "quests-scn", ext: "json")
        )
    }

    private static func bundleData(named name: String, ext: String) -> Data? {
        [
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "BundleAssets")
        ].compactMap { $0 }.first.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
    }

    private static func timerInput(from state: GameDataState) -> TimerProjectionInput {
        let fleet = state.fleet
        let expeditions = fleet.decks.values.map { deck in
            ExpeditionTimerInput(
                fleetIndex: deck.id,
                fleetName: deck.name,
                missionID: deck.expedition?.missionID ?? 0,
                arrivalDate: deck.expedition?.completionTime.map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                },
                isActive: deck.expedition?.isActive ?? false
            )
        }
        let dockings = fleet.repairDocks.values.map { dock in
            let shipID = dock.shipID ?? 0
            let masterID = fleet.ships[shipID]?.masterShipID
            return DockingTimerInput(
                dockIndex: dock.id,
                state: dock.state,
                shipID: shipID,
                shipName: masterID.flatMap { state.master.ships[$0]?.name } ?? "",
                completionDate: dock.completionTime.map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                }
            )
        }
        let morales = fleet.decks.values.compactMap { deck -> MoraleTimerInput? in
            let conditions = deck.shipIDs.compactMap { fleet.ships[$0]?.condition }
            guard let minimum = conditions.min() else { return nil }
            return MoraleTimerInput(
                fleetIndex: deck.id,
                fleetName: deck.name,
                condition: minimum
            )
        }
        let firstDeck = fleet.decks[1]
        let flagship = firstDeck?.shipIDs.first.flatMap { fleet.ships[$0] }
        let isAkashi = flagship.map {
            FleetWarningEvaluator.akashiMasterShipIDs.contains($0.masterShipID)
        } ?? false
        let signature = firstDeck?.shipIDs.map(String.init).joined(separator: ",") ?? ""

        return TimerProjectionInput(
            sourceRevision: state.revision,
            expeditions: expeditions,
            dockings: dockings,
            morales: morales,
            akashi: AkashiTimerInput(
                hasValidFlagship: isAkashi,
                formationSignature: signature
            )
        )
    }

    /// Small process-local deterministic hash. It contains no token material and
    /// is used only to suppress duplicate bridge deliveries.
    private static func eventID(endpoint: String, request: String?, response: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (endpoint + "\u{0}" + (request ?? "") + "\u{0}" + response).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
