import SwiftUI
import WebKit
import GameCore

struct RootView: View {
    private enum Phase {
        case entrance, starting, game, failed
    }

    @State private var phase: Phase = .entrance
    @State private var proxy = LocalProxyServer()
    @State private var bridge = JSBridge()
    @State private var selectedConnector: BrowserConstants.Connector?
    @State private var presentedDestination: GameMenuDestination?
    @State private var alertMessage: String?
    @State private var showsCertificateFallbackPrompt = false
    @State private var showsCertificateInstall = false
    @State private var screenshotSaveInFlight = false
    @State private var lastScreenshotSaveAt: Date?
    @State private var gameStateModel: GameStateModel
    @State private var dataSession: UInt64 = 0
    @StateObject private var subtitleCoordinator: SubtitleCoordinator

    private let settings: SettingsStore
    private let loginAutomation = LoginAutomation()
    private let screenshotSaver = ScreenshotSaver()
    private let dataCoordinator: GameDataCoordinator
    private let notificationService: NotificationService

    init() {
        let settings = SettingsStore()
        let gameStateModel = GameStateModel()
        let notificationService = NotificationService()
        self.notificationService = notificationService
        self.settings = settings
        self.dataCoordinator = GameDataCoordinator(
            model: gameStateModel,
            notificationService: notificationService,
            settings: settings
        )
        _gameStateModel = State(initialValue: gameStateModel)
        _subtitleCoordinator = StateObject(
            wrappedValue: SubtitleCoordinator(settings: settings)
        )
    }

    var body: some View {
        Group {
            switch phase {
            case .entrance:
                EntranceView(settings: settings) { connector, credentials in
                    startGame(using: connector, credentials: credentials)
                } onOpenSettings: {
                    presentedDestination = .settings
                }
            case .starting:
                ProgressView("启动本地代理…")
            case .game:
                if let connector = selectedConnector {
                    GameView(
                        url: connector.url,
                        proxyPort: proxy.port,
                        settings: settings,
                        bridge: bridge,
                        gameStateModel: gameStateModel,
                        subtitleCoordinator: subtitleCoordinator,
                        onNavigationFinished: { webView in
                            loginAutomation.handlePageFinished(
                                webView,
                                connector: connector
                            )
                        },
                        onOpenDestination: { destination in
                            presentedDestination = destination
                        },
                        onExit: exitGame
                    )
                }
            case .failed:
                ContentUnavailableView {
                    Label("代理启动失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("请返回重试；游戏不会在未经过本地代理时静默加载。")
                } actions: {
                    Button("返回") { exitGame() }
                }
            }
        }
        .fullScreenCover(item: $presentedDestination) { destination in
            destinationSheet(destination)
        }
        .sheet(isPresented: $showsCertificateInstall) {
            NavigationStack {
                CertificateInstallView()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "kancollegame", url.host == "fleet" else { return }
            presentedDestination = .fleet
        }
        .alert("未启用证书完全信任", isPresented: $showsCertificateFallbackPrompt) {
            Button("安装证书") {
                showsCertificateInstall = true
            }
            Button("继续盲隧道", role: .cancel) {}
        } message: {
            Text("本次启动已禁用实验性 HTTPS 资源解密并回退为普通盲隧道。游戏及舰队/战斗/任务 API 解析仍可正常使用，仅资源缓存和脚本补丁暂不可用。")
        }
        .alert("提示", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func destinationSheet(_ destination: GameMenuDestination) -> some View {
        if destination == .fleet {
            FleetOverlayView(
                gameState: gameStateModel.state,
                timers: gameStateModel.timers,
                warningConfiguration: FleetWarningConfiguration(
                    onlyLockedShipsOrEquipment: settings.heavyDamageLockedOnly,
                    minimumLevel: settings.heavyDamageMinimumLevel
                ),
                onClose: { presentedDestination = nil }
            )
        } else if destination == .tools {
            ToolsOverlayView(
                timers: gameStateModel.timers,
                gameState: gameStateModel.state,
                onClose: { presentedDestination = nil }
            )
        } else if destination == .battle {
            BattleOverlayView(
                snapshot: gameStateModel.battle,
                interruptedSnapshot: gameStateModel.interruptedBattle,
                logs: gameStateModel.battleLogs,
                result: gameStateModel.battleResult,
                shipNames: Dictionary(
                    uniqueKeysWithValues: gameStateModel.state.master.ships.map {
                        ($0.key, $0.value.name)
                    }
                ),
                onClose: { presentedDestination = nil }
            )
        } else if destination == .quest {
            QuestOverlayView(
                snapshot: gameStateModel.quests,
                definitions: gameStateModel.questDefinitions,
                isStale: gameStateModel.isStale,
                onClose: { presentedDestination = nil }
            )
        } else {
            NavigationStack {
                Group {
                    if destination == .settings {
                    SettingsView(
                        settings: settings,
                        notificationService: notificationService,
                        onNotificationSettingsChanged: {
                            Task { await dataCoordinator.refreshNotifications() }
                        }
                    )
                    } else {
                        ContentUnavailableView(
                            destination.rawValue,
                            systemImage: destination.symbol,
                            description: Text("该模块将在后续里程碑接入完整数据功能。")
                        )
                    }
                }
                .navigationTitle(destination.rawValue)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { presentedDestination = nil }
                    }
                }
            }
        }
    }

    private func startGame(
        using connector: BrowserConstants.Connector,
        credentials: KeychainStore.Credentials?
    ) {
        guard phase == .entrance || phase == .failed else { return }
        selectedConnector = connector
        loginAutomation.beginSession(credentials: credentials)
        var updatedSettings = settings
        updatedSettings.connector = connector
        phase = .starting

        Task {
            dataSession = await dataCoordinator.startSession()
            await configureMITMForThisLaunch()
            configureProxyHandlers(settings: settings)
            configureBridge()

            do {
                try proxy.start { result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            phase = .game
                        case .failure(let error):
                            alertMessage = error.localizedDescription
                            phase = .failed
                        }
                    }
                }
            } catch {
                alertMessage = error.localizedDescription
                phase = .failed
            }
        }
    }

    @MainActor
    private func configureMITMForThisLaunch() async {
        guard settings.mitmEnabled else {
            // DMM/game HTTPS stays end-to-end encrypted. API responses are
            // collected by the all-frame WKUserScript bridge, so fleet/battle/
            // quest parsing remains available without terminating TLS locally.
            proxy.mitmCA = nil
            return
        }

        let certificateAuthority = MitmCA()
        let trustModel = CertificateTrustModel(
            certificateAuthority: certificateAuthority
        )
        await trustModel.recheckTrust()
        if trustModel.state == .trusted {
            proxy.mitmCA = certificateAuthority
        } else {
            // Never begin a TLS interception handshake with an untrusted root.
            // The whole launch uses a blind CONNECT tunnel instead.
            proxy.mitmCA = nil
            showsCertificateFallbackPrompt = true
        }
    }

    private func exitGame() {
        dataSession = 0
        Task { await dataCoordinator.stopSession() }
        proxy.stop()
        proxy.onRequest = nil
        proxy.onGameResourceRequest = nil
        loginAutomation.endSession()
        screenshotSaveInFlight = false
        lastScreenshotSaveAt = nil
        selectedConnector = nil
        phase = .entrance
        OrientationLock.releaseLandscape()
    }

    private func configureProxyHandlers(settings: SettingsStore) {
        let diagnostics = DiagnosticsStore.shared
        proxy.onRequest = { entry in
            let status = entry.statusCode.map(String.init) ?? "---"
            let path = entry.path.hasPrefix("CONNECT:")
                ? "CONNECT \(entry.host):\(entry.path.dropFirst("CONNECT:".count))"
                : "\(entry.host)\(entry.path)"
            Task { @MainActor in
                diagnostics.recordProxyLog("[\(status)] \(path)")
            }
        }

        do {
            let cacheRoot = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("browser_cache", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cacheRoot,
                withIntermediateDirectories: true
            )
            let versions = try VersionStore(
                path: cacheRoot.appendingPathComponent("versions.sqlite").path
            )
            let resourceCache = ResourceCache(
                cacheDir: cacheRoot.appendingPathComponent("resources"),
                versionStore: versions,
                settings: settings,
                onVoiceResource: { event in
                    Task { @MainActor in
                        subtitleCoordinator.receiveVoiceResource(event)
                    }
                }
            )
            proxy.onGameResourceRequest = { head in
                resourceCache.response(for: head)
            }
        } catch {
            diagnostics.recordProxyLog("[CACHE] 初始化失败：\(error.localizedDescription)")
        }
    }

    private func configureBridge() {
        bridge.onEvent = { event in
            switch event {
            case .capture(let dataURL):
                let now = Date()
                guard !screenshotSaveInFlight,
                      lastScreenshotSaveAt.map({
                          now.timeIntervalSince($0) >= 2
                      }) ?? true else {
                    DiagnosticsStore.shared.recordProxyLog(
                        "[CAPTURE] 忽略重复或过快的截图请求"
                    )
                    return
                }
                screenshotSaveInFlight = true
                lastScreenshotSaveAt = now
                Task { @MainActor in
                    defer { screenshotSaveInFlight = false }
                    do {
                        _ = try await screenshotSaver.save(dataURL: dataURL)
                        alertMessage = "截图已保存到照片。"
                    } catch {
                        alertMessage = error.localizedDescription
                    }
                }
            case .kcsapi(let endpoint, let request, let response):
                DiagnosticsStore.shared.recordProxyLog("[API] \(endpoint)")
                subtitleCoordinator.receiveAPIResponse(
                    endpoint: endpoint,
                    response: response
                )
                let session = dataSession
                guard session != 0 else { return }
                Task {
                    await dataCoordinator.ingest(
                        endpoint: endpoint,
                        request: request,
                        response: response,
                        session: session
                    )
                }
            case .apiError(let code):
                DiagnosticsStore.shared.recordProxyLog("[APIERR] code=\(code)")
            case .log(let message):
                DiagnosticsStore.shared.recordProxyLog("[JS] \(message)")
            case .memoryReport:
                break
            }
        }
        loginAutomation.onError = { error in
            alertMessage = error.localizedDescription
        }
    }
}

extension GameMenuDestination: Identifiable {
    var id: String { rawValue }
}
