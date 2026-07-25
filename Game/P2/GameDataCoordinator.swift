import Foundation
import GameCore

actor GameDataCoordinator {
    private let pipeline = GameDataPipeline()
    private var projector = TimerProjector()
    private let model: GameStateModel
    private let store: GameSnapshotStore?
    private let notificationService: NotificationService
    private let notificationSettings: NotificationPlanner.Settings
    private var generation: UInt64 = 0

    init(
        model: GameStateModel,
        notificationService: NotificationService,
        settings: SettingsStore
    ) {
        self.model = model
        self.notificationService = notificationService
        notificationSettings = .init(
            expeditionEnabled: settings.expeditionNotificationsEnabled,
            dockingEnabled: settings.dockingNotificationsEnabled,
            moraleEnabled: settings.moraleNotificationsEnabled,
            akashiEnabled: settings.akashiNotificationsEnabled,
            leadTime: TimeInterval(settings.notificationLeadTimeSeconds)
        )
        if let url = try? SharedContainer.snapshotDatabaseURL() {
            store = try? GameSnapshotStore(path: url.path)
        } else {
            store = nil
        }
    }

    @discardableResult
    func startSession() async -> UInt64 {
        generation &+= 1
        let currentGeneration = generation
        await pipeline.reset()
        projector = TimerProjector()

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
            let before = await pipeline.state().revision
            let event = try await pipeline.ingest(
                endpoint: endpoint,
                response: responseData,
                requestBody: requestData,
                eventID: eventID
            )
            guard session == generation else { return }
            let state = await pipeline.state()
            guard state.revision > before else {
                if case .incrementalUpdated(_, let warnings) = event, !warnings.isEmpty {
                    await model.report(warnings.joined(separator: "；"))
                }
                return
            }

            let projection = projector.project(Self.timerInput(from: state))
            try store?.save(
                state: state,
                revision: state.revision,
                timers: projection.timers
            )
            await model.publish(state: state, timers: projection.timers)
            await notificationService.reconcile(
                timers: projection.timers,
                plannerSettings: notificationSettings
            )
        } catch {
            let safeEndpoint = String(endpoint.prefix(160))
            await model.report("\(safeEndpoint)：\(error.localizedDescription)")
        }
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
