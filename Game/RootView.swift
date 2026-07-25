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

    private let settings = SettingsStore()
    private let loginAutomation = LoginAutomation()
    private let screenshotSaver = ScreenshotSaver()

    var body: some View {
        Group {
            switch phase {
            case .entrance:
                EntranceView(settings: settings) { connector in
                    startGame(using: connector)
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
        .sheet(item: $presentedDestination) { destination in
            destinationSheet(destination)
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
        NavigationStack {
            Group {
                if destination == .settings {
                    CertificateInstallView()
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

    private func startGame(using connector: BrowserConstants.Connector) {
        guard phase == .entrance || phase == .failed else { return }
        selectedConnector = connector
        var updatedSettings = settings
        updatedSettings.connector = connector
        proxy.mitmCA = settings.mitmEnabled ? MitmCA() : nil
        configureProxyHandlers(settings: settings)
        configureBridge()
        phase = .starting

        do {
            try proxy.start()
        } catch {
            alertMessage = error.localizedDescription
            phase = .failed
            return
        }

        Task {
            for _ in 0..<30 where proxy.port == 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            phase = proxy.port == 0 ? .failed : .game
        }
    }

    private func exitGame() {
        proxy.stop()
        proxy.onRequest = nil
        proxy.onGameResourceRequest = nil
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
                settings: settings
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
                Task {
                    do {
                        _ = try await screenshotSaver.save(dataURL: dataURL)
                        alertMessage = "截图已保存到照片。"
                    } catch {
                        alertMessage = error.localizedDescription
                    }
                }
            case .kcsapi(let endpoint, _, _):
                DiagnosticsStore.shared.recordProxyLog("[API] \(endpoint)")
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
