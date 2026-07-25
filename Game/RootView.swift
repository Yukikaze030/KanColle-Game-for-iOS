import SwiftUI
import GameCore

/// 临时 RootView（任务 6 Spike 用，任务 12+ 会替换为正式导航结构）。
struct RootView: View {
    @State private var proxy = LocalProxyServer()
    @State private var bridge = JSBridge()
    @State private var started = false

    var body: some View {
        Group {
            if started {
                BrowserView(url: SettingsStore().connector.url, proxyPort: proxy.port,
                            settings: SettingsStore(), bridge: bridge)
                    .ignoresSafeArea()
            } else {
                ProgressView("启动代理…")
            }
        }
        .onAppear {
            guard !started else { return }
            try? proxy.start()
            Task {
                for _ in 0..<20 where proxy.port == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
                started = true
            }
        }
    }
}
