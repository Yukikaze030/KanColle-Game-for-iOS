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
    // TODO(任务6后清理)：Spike 日志面板显隐（默认展开）
    @State private var showLogPanel = true

    var body: some View {
        Group {
            switch proxyState {
            case .ready:
                // 仅代理就绪（port != 0）才加载 BrowserView，避免静默直连
                // 导致 Spike 得出虚假结论
                ZStack {
                    BrowserView(url: SettingsStore().connector.url, proxyPort: proxy.port,
                                settings: SettingsStore(), bridge: bridge)
                        .ignoresSafeArea()
                }
                // TODO(任务6后清理)：Spike 日志面板与开关
                .overlay(alignment: .bottom) {
                    if showLogPanel { logPanel }
                }
                .overlay(alignment: .topTrailing) {
                    Button(showLogPanel ? "隐藏日志" : "日志") {
                        showLogPanel.toggle()
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(8)
                }
            case .starting:
                ProgressView("启动代理…")
            case .failed:
                Text("代理启动失败")
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            guard proxyState == .starting else { return }
            installSpikeProbes()
            try? proxy.start()
            Task {
                for _ in 0..<20 where proxy.port == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
                proxyState = proxy.port != 0 ? .ready : .failed
            }
        }
    }

    // MARK: - TODO(任务6后清理)：Spike 探针（代理日志 / main.js 探针 / kcsapi·内存探针）

    private func installSpikeProbes() {
        let store = DiagnosticsStore.shared
        // 代理请求日志。回调在代理并发队列触发，跳主线程再写 @Observable 存储。
        // 格式：[状态码] host/path；blocked 前缀 [B]（面板标红）；main.js 标注 [MAIN.JS]。
        proxy.onRequest = { entry in
            let status = entry.statusCode.map(String.init) ?? "---"
            var line = "[\(status)] "
            if entry.path.contains("/kcs2/js/main.js") { line += "[MAIN.JS] " }
            line += "\(entry.host)\(entry.path)"
            if entry.blocked { line = "[B] " + line }
            Task { @MainActor in store.recordProxyLog(line) }
        }
        // main.js 补丁探针 + 通用明文游戏流量探针：本任务不缓存，一律放行（nil），仅打日志。
        // 注意：此回调仅对 isInspectableHost 命中的请求触发，故全部加 [KC] 前缀。
        proxy.onGameResourceRequest = { head in
            var line = "[KC] "
            if head.path.contains("/kcs2/js/main.js") { line += "[MAIN.JS] " }
            line += "\(head.method) \(head.host)\(head.path)"
            Task { @MainActor in store.recordProxyLog(line) }
            return nil
        }
        // kcsapi / 内存探针 / 截图 / API 错误事件（WKScriptMessageHandler 本就在主线程回调）
        bridge.onEvent = { event in
            switch event {
            case .kcsapi(let endpoint, _, _):
                store.recordProxyLog("[API] \(endpoint)")
            case .memoryReport(let jsHeapMB):
                store.recordMemoryProbeLog(jsHeapMB: jsHeapMB)
            case .capture:
                store.recordProxyLog("[CAPTURE] 截图 dataURL 已收到")
            case .apiError(let code):
                store.recordProxyLog("[APIERR] code=\(code)")
            case .log(let message):
                store.recordProxyLog("[JS] \(message)")
            }
        }
    }

    // TODO(任务6后清理)：Spike 底部日志面板（最新 50 条，等宽 9pt，blocked 标红）
    private var logPanel: some View {
        let lines = Array(DiagnosticsStore.shared.proxyLogs.suffix(50))
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i])
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(lines[i].hasPrefix("[B]") ? Color.red : Color.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("logBottom")
                }
                .padding(4)
            }
            .frame(height: 160)
            .background(Color.black.opacity(0.7))
            .onChange(of: DiagnosticsStore.shared.proxyLogs.count) { _, _ in
                reader.scrollTo("logBottom", anchor: .bottom)
            }
        }
    }
}
