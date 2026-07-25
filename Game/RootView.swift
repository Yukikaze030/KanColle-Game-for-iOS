import SwiftUI
import GameCore

// TODO(任务12)：临时 RootView（任务 6 Spike 用，任务 12+ 会替换为正式导航结构）。
struct RootView: View {
    enum ProxyState {
        case idle, starting, ready, failed
    }

    @State private var proxy = LocalProxyServer()
    @State private var bridge = JSBridge()
    @State private var proxyState: ProxyState = .idle
    // TODO(任务6后清理)：Spike 日志面板显隐（默认展开）
    @State private var showLogPanel = true
    // TODO(任务6后清理)：Spike 连接器选择（点击后才启动代理并加载对应 URL）
    @State private var selectedConnector: BrowserConstants.Connector?
    @State private var showCertificateInstall = false

    var body: some View {
        Group {
            switch proxyState {
            case .ready:
                // 仅代理就绪（port != 0）才加载 BrowserView，避免静默直连
                // 导致 Spike 得出虚假结论
                ZStack {
                    BrowserView(url: selectedConnector?.url ?? SettingsStore().connector.url,
                                proxyPort: proxy.port,
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
            case .idle:
                // TODO(任务6后清理)：Spike 连接器选择入口（任务 12+ 由正式设置页替代）
                VStack(spacing: 16) {
                    Text("选择连接器")
                        .font(.headline)
                    ForEach(BrowserConstants.Connector.allCases, id: \.self) { connector in
                        Button(connector.rawValue) {
                            selectConnector(connector)
                        }
                        .font(.system(size: 16, design: .monospaced))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.7))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    Button {
                        showCertificateInstall = true
                    } label: {
                        Label("安装游戏加速证书", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.bordered)
                }
            case .starting:
                ProgressView("启动代理…")
            case .failed:
                Text("代理启动失败")
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            // TODO(任务6后清理)：冒烟测试钩子——支持启动参数 -SpikeConnector <rawValue>
            //（如 "DMM direct"）自动选择连接器，省去人工点击；默认不带参数时停在选择页。
            guard proxyState == .idle,
                  let raw = UserDefaults.standard.string(forKey: "SpikeConnector"),
                  let connector = BrowserConstants.Connector(rawValue: raw) else { return }
            selectConnector(connector)
        }
        .sheet(isPresented: $showCertificateInstall) {
            NavigationStack {
                CertificateInstallView()
            }
        }
    }

    // TODO(任务6后清理)：Spike 连接器选择——点击后才装探针、启动代理
    private func selectConnector(_ connector: BrowserConstants.Connector) {
        guard proxyState == .idle else { return }
        selectedConnector = connector
        var settings = SettingsStore()
        settings.connector = connector
        proxyState = .starting
        installSpikeProbes()
        try? proxy.start()
        Task {
            for _ in 0..<20 where proxy.port == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            proxyState = proxy.port != 0 ? .ready : .failed
        }
    }

    // MARK: - TODO(任务6后清理)：Spike 探针（代理日志 / main.js 探针 / kcsapi·内存探针）

    private func installSpikeProbes() {
        let store = DiagnosticsStore.shared
        // 代理请求日志。回调在代理并发队列触发，跳主线程再写 @Observable 存储。
        // 格式：[状态码] host/path（CONNECT 隧道为 [状态码] CONNECT host:port）；
        // blocked 前缀 [B]（面板标红）；main.js 标注 [MAIN.JS]。
        proxy.onRequest = { entry in
            let status = entry.statusCode.map(String.init) ?? "---"
            var line = "[\(status)] "
            if entry.path.hasPrefix("CONNECT:") {
                line += "CONNECT \(entry.host):\(entry.path.dropFirst("CONNECT:".count))"
            } else {
                if entry.path.contains("/kcs2/js/main.js") { line += "[MAIN.JS] " }
                line += "\(entry.host)\(entry.path)"
            }
            if entry.blocked { line = "[B] " + line }
            Task { @MainActor in store.recordProxyLog(line) }
        }
        // 明文游戏流量探针 + main.js 内容改写探针。
        // 注意：此回调仅对 isInspectableHost 命中的请求触发，故全部加 [KC] 前缀。
        proxy.onGameResourceRequest = { head in
            let isMainJS = head.path.contains("/kcs2/js/main.js")
            var line = "[KC] "
            if isMainJS { line += "[MAIN.JS] " }
            line += "\(head.method) \(head.host)\(head.path)"
            Task { @MainActor in store.recordProxyLog(line) }
            // TODO(任务6后清理)：main.js 内容改写探针——同步拉取上游完整内容，
            // body 末尾追加 window.__SPIKE_PATCHED=1 标记后本地返回，
            // 验证"代理可改写响应内容"（页面侧探针脚本读到标记后上报 SPIKE_PATCHED_OK）。
            // 回调在代理并发队列触发，阻塞单个线程 Spike 阶段可接受；拉取失败则放行回源。
            if isMainJS, let url = URL(string: "http://\(head.host)\(head.path)"),
               var body = try? Data(contentsOf: url, options: .uncached) {
                body.append(Data(";window.__SPIKE_PATCHED=1;".utf8))
                Task { @MainActor in store.recordProxyLog("[KC] [MAIN.JS] PATCHED \(body.count)B") }
                return ResourceResponse(statusCode: 200,
                                        headers: [("Content-Type", "application/javascript")],
                                        body: body)
            }
            // 其余请求一律放行（nil），本任务不缓存
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
