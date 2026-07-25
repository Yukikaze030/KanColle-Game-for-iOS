import SwiftUI
import GameCore

// TODO(任务12)：临时 RootView（任务 6 Spike 用，任务 12+ 会替换为正式导航结构）。
struct RootView: View {
    enum ProxyState {
        case starting, ready, failed
    }

    @State private var proxy = LocalProxyServer()
    @State private var bridge = JSBridge()
    @State private var proxyState: ProxyState = .starting

    var body: some View {
        Group {
            switch proxyState {
            case .ready:
                // 仅代理就绪（port != 0）才加载 BrowserView，避免静默直连
                // 导致 Spike 得出虚假结论
                BrowserView(url: SettingsStore().connector.url, proxyPort: proxy.port,
                            settings: SettingsStore(), bridge: bridge)
                    .ignoresSafeArea()
            case .starting:
                ProgressView("启动代理…")
            case .failed:
                Text("代理启动失败")
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            guard proxyState == .starting else { return }
            try? proxy.start()
            Task {
                for _ in 0..<20 where proxy.port == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
                proxyState = proxy.port != 0 ? .ready : .failed
            }
        }
    }
}
