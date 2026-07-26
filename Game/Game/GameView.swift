import SwiftUI
import WebKit
import GameCore

struct GameView: View {
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
    @State private var recoveryMessage: String?
    @State private var memoryMonitor: MemoryMonitor

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
                        onProcessTerminated: webContentProcessDidTerminate)
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

            if let recoveryMessage {
                Text(recoveryMessage)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .alert("内存占用过高", isPresented: $showsMemoryWarning) {
            Button("清理缓存") {
                URLCache.shared.removeAllCachedResponses()
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
        guard settings.memoryWarnEnabled else { return }
        memoryMonitor.onThresholdExceeded = {
            showsMemoryWarning = true
        }
        memoryMonitor.onSystemMemoryWarning = {
            URLCache.shared.removeAllCachedResponses()
            showsMemoryWarning = true
        }
        memoryMonitor.start()
    }

    private func webContentProcessDidTerminate() {
        withAnimation { recoveryMessage = "页面进程已重启，正在自动恢复…" }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { recoveryMessage = nil }
        }
    }
}
