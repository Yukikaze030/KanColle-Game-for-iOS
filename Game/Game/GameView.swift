import SwiftUI
import WebKit
import GameCore

struct GameView: View {
    @Environment(\.scenePhase) private var scenePhase

    let url: URL
    let proxyPort: UInt16
    let settings: SettingsStore
    let bridge: JSBridge
    let gameStateModel: GameStateModel
    @ObservedObject var subtitleCoordinator: SubtitleCoordinator
    let onNavigationFinished: (WKWebView) -> Void
    let onOpenDestination: (GameMenuDestination) -> Void
    let onExit: () -> Void

    @StateObject private var browserController = BrowserController()
    @State private var showsMenu = false
    @State private var isMuted: Bool
    @State private var isGameReady = false
    @State private var showsMemoryWarning = false
    @State private var recoveryRequired: RecoveryRequired?
    @State private var navigationError: String?
    @State private var sortieRiskAlert: String?
    @State private var warnedBattleSessionID: UUID?
    @State private var browserGeneration = 0
    @State private var memoryMonitor: MemoryMonitor

    private struct RecoveryRequired {
        let terminationCount: Int
        let switchedFromCanvasToWebGL: Bool
    }

    init(url: URL,
         proxyPort: UInt16,
         settings: SettingsStore,
         bridge: JSBridge,
         gameStateModel: GameStateModel,
         subtitleCoordinator: SubtitleCoordinator,
         onNavigationFinished: @escaping (WKWebView) -> Void = { _ in },
         onOpenDestination: @escaping (GameMenuDestination) -> Void,
         onExit: @escaping () -> Void) {
        self.url = url
        self.proxyPort = proxyPort
        self.settings = settings
        self.bridge = bridge
        self.gameStateModel = gameStateModel
        self.subtitleCoordinator = subtitleCoordinator
        self.onNavigationFinished = onNavigationFinished
        self.onOpenDestination = onOpenDestination
        self.onExit = onExit
        _isMuted = State(initialValue: settings.silentStart)
        let configuredThreshold = settings.memoryWarnThresholdMB > 0
            ? Double(settings.memoryWarnThresholdMB)
            : nil
        _memoryMonitor = State(
            initialValue: MemoryMonitor(thresholdMB: configuredThreshold)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BrowserView(url: url,
                        proxyPort: proxyPort,
                        settings: settings,
                        bridge: bridge,
                        controller: browserController,
                        onNavigationFinished: onNavigationFinished,
                        onGameReady: gameDidBecomeReady,
                        onRecovery: handleRecovery,
                        onNavigationError: { navigationError = $0 })
                .id(browserGeneration)
                .ignoresSafeArea()

            if settings.subtitleEnabled {
                SubtitleBarView(
                    match: subtitleCoordinator.currentMatch,
                    fontSize: settings.subtitleFontSize
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
            }

            if isGameReady, settings.parsedDataHUDEnabled {
                ParsedDataHUDView(
                    model: gameStateModel,
                    onOpenDetail: openDestination
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 18)
                .padding(.top, 14)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if isGameReady, showsMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showsMenu = false }

                FloatingMenuView(
                    isMuted: isMuted,
                    onDestination: openDestination,
                    onScreenshot: capture,
                    onToggleMute: toggleMute,
                    onReload: {
                        showsMenu = false
                        browserController.reload()
                    },
                    onExit: {
                        showsMenu = false
                        onExit()
                    }
                )
                .padding(.horizontal, 72)
                .frame(maxHeight: .infinity, alignment: .center)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            if isGameReady {
                FloatingBallView(isExpanded: showsMenu) {
                    withAnimation(.snappy(duration: 0.22)) {
                        showsMenu.toggle()
                    }
                }
            }

        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(isGameReady)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
            startHealthMonitoring()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            memoryMonitor.stop()
            if isGameReady { OrientationLock.releaseLandscape() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Reclaim only disposable HTTP/WebKit cache state while the game is
            // suspended. Active Canvas/WebGL resources belong to WebContent and
            // cannot be safely or forcibly collected through public APIs.
            if phase == .background {
                browserController.purgeVolatileCaches()
            }
        }
        .onChange(of: gameStateModel.battle?.revision) { _, _ in
            guard let battle = gameStateModel.battle,
                  battle.sessionID != warnedBattleSessionID,
                  battle.status == .active else { return }
            let assessments = DameconResolver.assessments(in: battle).values
            if assessments.contains(.sunk) {
                warnedBattleSessionID = battle.sessionID
                sortieRiskAlert = "检测到沉没状态。请不要在游戏中继续进击，并核对战斗数据。"
            } else if assessments.contains(.heavyDamaged) {
                warnedBattleSessionID = battle.sessionID
                sortieRiskAlert = "舰队出现大破且未检测到损管。请在游戏的进击/撤退选择中优先撤退。"
            }
        }
        .alert("大破进击警告", isPresented: Binding(
            get: { sortieRiskAlert != nil },
            set: { if !$0 { sortieRiskAlert = nil } }
        )) {
            Button("我已了解", role: .cancel) { sortieRiskAlert = nil }
        } message: {
            Text(sortieRiskAlert ?? "")
        }
        .alert("内存占用过高", isPresented: $showsMemoryWarning) {
            Button("清理缓存") {
                browserController.purgeVolatileCaches()
            }
            if settings.legacyRenderer {
                Button("切换 WebGL 并重载") {
                    browserController.switchToWebGLAndReload()
                }
            }
            Button("重新加载") {
                browserController.reload()
            }
            Button("忽略", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: "当前 App 占用 %.0f MB，告警阈值 %.0f MB。",
                    memoryMonitor.residentMB,
                    memoryMonitor.thresholdMB
                )
            )
        }
        .alert("游戏页面进程已终止", isPresented: Binding(
            get: { recoveryRequired != nil },
            set: { if !$0 { recoveryRequired = nil } }
        )) {
            Button("稳定模式重建") {
                recoveryRequired = nil
                var writableSettings = settings
                writableSettings.legacyRenderer = false
                writableSettings.fpsUnlockEnabled = false
                rebuildBrowser()
            }
            Button("退出游戏", role: .destructive) {
                recoveryRequired = nil
                onExit()
            }
            Button("暂不重载", role: .cancel) {}
        } message: {
            Text(recoveryRequiredMessage)
        }
        .alert("网络或 SSL 加载失败", isPresented: Binding(
            get: { navigationError != nil },
            set: { if !$0 { navigationError = nil } }
        )) {
            Button("重新加载") {
                navigationError = nil
                browserController.reload()
            }
            Button("重建浏览器") {
                navigationError = nil
                rebuildBrowser()
            }
            Button("忽略", role: .cancel) { navigationError = nil }
        } message: {
            Text(navigationError ?? "")
        }
    }

    private func openDestination(_ destination: GameMenuDestination) {
        showsMenu = false
        onOpenDestination(destination)
    }

    private func capture() {
        showsMenu = false
        let script = settings.connector == .dmm
            ? BrowserConstants.captureSendDMM
            : BrowserConstants.captureSendOOI
        browserController.evaluateJavaScript(script)
    }

    private func toggleMute() {
        isMuted.toggle()
        showsMenu = false
        applyMute(isMuted)
    }

    private func applyMute(_ muted: Bool) {
        let template = settings.connector == .dmm
            ? BrowserConstants.muteSendDMM
            : BrowserConstants.muteSendOOI
        browserController.evaluateJavaScript(String(format: template, muted ? 1 : 0))
    }

    private func gameDidBecomeReady() {
        guard !isGameReady else { return }
        isGameReady = true
        OrientationLock.lockLandscape()
        applyMute(isMuted)
    }

    private func startHealthMonitoring() {
        memoryMonitor.onThresholdExceeded = {
            if settings.memoryWarnEnabled {
                showsMemoryWarning = true
            }
        }
        memoryMonitor.onSystemMemoryWarning = {
            browserController.purgeVolatileCaches()
            if settings.memoryWarnEnabled {
                showsMemoryWarning = true
            }
        }
        memoryMonitor.start()
    }

    private func handleRecovery(_ event: WebContentRecoveryEvent) {
        switch event {
        case .reloadRequired(let terminationCount, let switchedRenderer):
            recoveryRequired = .init(
                terminationCount: terminationCount,
                switchedFromCanvasToWebGL: switchedRenderer
            )
        }
    }

    private var recoveryRequiredMessage: String {
        let rendererNote = recoveryRequired?.switchedFromCanvasToWebGL == true
            ? "检测到 Canvas 会话，本次重建将改用 WebGL。"
            : ""
        return """
        WebContent 已被系统终止，本地 JavaScript/Canvas 运行态在重载前就已经丢失。\
        App 不会再自动刷新，以免无提示地离开当前进度。\
        \(rendererNote)“稳定模式重建”还会关闭帧率解锁。\
        这是本次会话第 \(recoveryRequired?.terminationCount ?? 1) 次终止。
        """
    }

    private func rebuildBrowser() {
        browserController.stopLoading()
        showsMenu = false
        isGameReady = false
        browserGeneration += 1
    }
}
