import SwiftUI
import GameCore

/// Complete user-facing settings surface. Values are copied into local state so
/// controls remain responsive, then persisted immediately through SettingsStore.
struct SettingsView: View {
    private struct SubtitleLanguage: Identifiable {
        let id: String
        let title: String
    }

    private static let subtitleLanguages = [
        SubtitleLanguage(id: "scn", title: "简体中文"),
        SubtitleLanguage(id: "tcn", title: "繁體中文"),
        SubtitleLanguage(id: "ja", title: "日本語"),
        SubtitleLanguage(id: "en", title: "English"),
        SubtitleLanguage(id: "ko", title: "한국어")
    ]

    private let settings: SettingsStore
    private let keychain: KeychainStore
    @State private var diagnostics: DiagnosticsStore

    @State private var connector: BrowserConstants.Connector
    @State private var silentStart: Bool
    @State private var legacyRenderer: Bool
    @State private var fpsUnlockEnabled: Bool
    @State private var cursorMode: SettingsStore.CursorMode
    @State private var keepScreenOn: Bool
    @State private var subtitleEnabled: Bool
    @State private var subtitleLocale: String
    @State private var subtitleFontSize: Int
    @State private var cacheEnabled: Bool
    @State private var alterGadget: Bool
    @State private var alterGadgetEndpoint: String
    @State private var downloadRetry: Bool
    @State private var mitmEnabled: Bool
    @State private var memoryWarnEnabled: Bool
    @State private var memoryWarnThresholdMB: Int
    @State private var battleOverlayAutoRefresh: Bool
    @State private var showEnemyEquipmentDetails: Bool
    @State private var battleLogRetentionCount: Int
    @State private var exactQuestTrackingEnabled: Bool
    @State private var questCompletionBannerEnabled: Bool
    @State private var parsedDataHUDEnabled: Bool

    @State private var isClearingCache = false
    @State private var confirmation: Confirmation?
    @State private var errorMessage: String?

    private enum Confirmation: String, Identifiable {
        case clearCache
        case clearCredentials
        var id: String { rawValue }
    }

    init(
        settings: SettingsStore = SettingsStore(),
        keychain: KeychainStore = KeychainStore(),
        diagnostics: DiagnosticsStore? = nil
    ) {
        self.settings = settings
        self.keychain = keychain
        _diagnostics = State(initialValue: diagnostics ?? .shared)
        _connector = State(initialValue: settings.connector)
        _silentStart = State(initialValue: settings.silentStart)
        _legacyRenderer = State(initialValue: settings.legacyRenderer)
        _fpsUnlockEnabled = State(initialValue: settings.fpsUnlockEnabled)
        _cursorMode = State(initialValue: settings.cursorMode)
        _keepScreenOn = State(initialValue: settings.keepScreenOn)
        _subtitleEnabled = State(initialValue: settings.subtitleEnabled)
        _subtitleLocale = State(initialValue: settings.subtitleLocale)
        _subtitleFontSize = State(initialValue: settings.subtitleFontSize)
        _cacheEnabled = State(initialValue: settings.cacheEnabled)
        _alterGadget = State(initialValue: settings.alterGadget)
        _alterGadgetEndpoint = State(initialValue: settings.alterGadgetEndpoint)
        _downloadRetry = State(initialValue: settings.downloadRetry)
        _mitmEnabled = State(initialValue: settings.mitmEnabled)
        _memoryWarnEnabled = State(initialValue: settings.memoryWarnEnabled)
        _memoryWarnThresholdMB = State(initialValue: settings.memoryWarnThresholdMB)
        _battleOverlayAutoRefresh = State(initialValue: settings.battleOverlayAutoRefresh)
        _showEnemyEquipmentDetails = State(initialValue: settings.showEnemyEquipmentDetails)
        _battleLogRetentionCount = State(initialValue: settings.battleLogRetentionCount)
        _exactQuestTrackingEnabled = State(initialValue: settings.exactQuestTrackingEnabled)
        _questCompletionBannerEnabled = State(initialValue: settings.questCompletionBannerEnabled)
        _parsedDataHUDEnabled = State(initialValue: settings.parsedDataHUDEnabled)
    }

    var body: some View {
        Form {
            browserSection
            subtitleSection
            cacheSection
            networkSection
            certificateSection
            NotificationSettingsSection(settings: settings)
            battleQuestSection
            memorySection
            diagnosticsSection
            privacySection
            versionSection
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch confirmation {
            case .clearCache?:
                Button("清理缓存", role: .destructive) { clearCache() }
            case .clearCredentials?:
                Button("清除全部凭证", role: .destructive) { clearCredentials() }
            case nil:
                EmptyView()
            }
            Button("取消", role: .cancel) {}
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var battleQuestSection: some View {
        Section {
            Toggle("战斗覆盖自动刷新", isOn: $battleOverlayAutoRefresh)
            Toggle("显示解析数据悬浮窗", isOn: $parsedDataHUDEnabled)
            Toggle("显示敌方装备详情", isOn: $showEnemyEquipmentDetails)
            Picker("保留战斗日志", selection: $battleLogRetentionCount) {
                Text("20 场").tag(20)
                Text("50 场").tag(50)
                Text("100 场").tag(100)
            }
            Toggle("任务精确追踪", isOn: $exactQuestTrackingEnabled)
            Toggle("任务完成提示", isOn: $questCompletionBannerEnabled)
        } header: {
            Text("战斗与任务")
        } footer: {
            Text("任务完成提示仅在 App 内显示，不占用本地通知配额。敌方装备详情默认关闭以减少常驻内存。")
        }
        .onChange(of: battleOverlayAutoRefresh) { _, value in
            update { $0.battleOverlayAutoRefresh = value }
        }
        .onChange(of: parsedDataHUDEnabled) { _, value in
            update { $0.parsedDataHUDEnabled = value }
        }
        .onChange(of: showEnemyEquipmentDetails) { _, value in
            update { $0.showEnemyEquipmentDetails = value }
        }
        .onChange(of: battleLogRetentionCount) { _, value in
            update { $0.battleLogRetentionCount = value }
        }
        .onChange(of: exactQuestTrackingEnabled) { _, value in
            update { $0.exactQuestTrackingEnabled = value }
        }
        .onChange(of: questCompletionBannerEnabled) { _, value in
            update { $0.questCompletionBannerEnabled = value }
        }
    }

    private var browserSection: some View {
        Section {
            Picker("连接器", selection: $connector) {
                ForEach(BrowserConstants.Connector.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            Toggle("静音启动", isOn: $silentStart)
            Picker("渲染器", selection: $legacyRenderer) {
                Text("Canvas（兼容模式）").tag(true)
                Text("WebGL").tag(false)
            }
            Toggle("移除 60 帧限制", isOn: $fpsUnlockEnabled)
            Picker("指针模式", selection: $cursorMode) {
                Text("触摸").tag(SettingsStore.CursorMode.touch)
                Text("鼠标").tag(SettingsStore.CursorMode.mouse)
            }
            Toggle("游戏时保持屏幕常亮", isOn: $keepScreenOn)
        } header: {
            Text("浏览器")
        } footer: {
            Text("Canvas 是兼容模式，对本游戏可能占用更多解码与绘图内存。页面进程终止后，本次会话会自动降级为 WebGL；帧率解锁也可能增加内存与渲染压力。修改后需重新进入游戏。")
        }
        .onChange(of: connector) { _, value in update { $0.connector = value } }
        .onChange(of: silentStart) { _, value in update { $0.silentStart = value } }
        .onChange(of: legacyRenderer) { _, value in update { $0.legacyRenderer = value } }
        .onChange(of: fpsUnlockEnabled) { _, value in update { $0.fpsUnlockEnabled = value } }
        .onChange(of: cursorMode) { _, value in update { $0.cursorMode = value } }
        .onChange(of: keepScreenOn) { _, value in update { $0.keepScreenOn = value } }
    }

    private var subtitleSection: some View {
        Section("字幕") {
            Toggle("显示语音字幕", isOn: $subtitleEnabled)
            Picker("语言", selection: $subtitleLocale) {
                ForEach(Self.subtitleLanguages) { language in
                    Text(language.title).tag(language.id)
                }
            }
            .disabled(!subtitleEnabled)
            Stepper(
                "字号：\(subtitleFontSize)",
                value: $subtitleFontSize,
                in: 12...36
            )
            .disabled(!subtitleEnabled)
        }
        .onChange(of: subtitleEnabled) { _, value in update { $0.subtitleEnabled = value } }
        .onChange(of: subtitleLocale) { _, value in update { $0.subtitleLocale = value } }
        .onChange(of: subtitleFontSize) { _, value in update { $0.subtitleFontSize = value } }
    }

    private var cacheSection: some View {
        Section {
            Toggle("启用资源缓存", isOn: $cacheEnabled)
            Button(role: .destructive) {
                confirmation = .clearCache
            } label: {
                HStack {
                    Label("清理资源缓存", systemImage: "trash")
                    if isClearingCache {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isClearingCache)
        } header: {
            Text("缓存")
        } footer: {
            Text("清理 browser_cache 资源文件及 VersionStore 版本记录；登录信息不会受影响。")
        }
        .onChange(of: cacheEnabled) { _, value in update { $0.cacheEnabled = value } }
    }

    private var networkSection: some View {
        Section {
            Toggle("启用 Gadget 绕行", isOn: $alterGadget)
            TextField("缓存端点", text: $alterGadgetEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(!alterGadget)
            Toggle("下载失败后重试", isOn: $downloadRetry)
        } header: {
            Text("网络与下载")
        } footer: {
            Text("Gadget 端点应为完整的 HTTPS URL。修改后对新请求生效。")
        }
        .onChange(of: alterGadget) { _, value in update { $0.alterGadget = value } }
        .onChange(of: alterGadgetEndpoint) { _, value in update { $0.alterGadgetEndpoint = value } }
        .onChange(of: downloadRetry) { _, value in update { $0.downloadRetry = value } }
    }

    private var certificateSection: some View {
        Section {
            Toggle("实验性 HTTPS 资源解密", isOn: $mitmEnabled)
            NavigationLink {
                CertificateInstallView()
            } label: {
                Label("安装与检测可选根证书", systemImage: "checkmark.shield")
            }
        } header: {
            Text("实验性资源补丁")
        } footer: {
            Text("默认关闭，DMM 使用普通加密隧道，舰队/战斗/任务数据仍由网页桥接解析。仅资源缓存或脚本补丁需要解密时启用；若出现黑屏请关闭并重新进入游戏。")
        }
        .onChange(of: mitmEnabled) { _, value in update { $0.mitmEnabled = value } }
    }

    private var memorySection: some View {
        Section {
            Toggle("内存过高时警告", isOn: $memoryWarnEnabled)
            Picker("告警阈值", selection: $memoryWarnThresholdMB) {
                Text("自动").tag(0)
                ForEach([256, 384, 512, 768, 1024, 1536], id: \.self) {
                    Text("\($0) MB").tag($0)
                }
            }
            .disabled(!memoryWarnEnabled)
        } header: {
            Text("内存")
        } footer: {
            Text("阈值仅监测 App 主进程的 phys_footprint。WKWebView 的 WebContent 是独立进程，公开 API 无法读取其内存，只能通过系统内存警告和页面进程终止间接判断。")
        }
        .onChange(of: memoryWarnEnabled) { _, value in update { $0.memoryWarnEnabled = value } }
        .onChange(of: memoryWarnThresholdMB) { _, value in
            update { $0.memoryWarnThresholdMB = value }
        }
    }

    private var diagnosticsSection: some View {
        Section("诊断") {
            LabeledContent(
                "当前 App phys_footprint",
                value: formattedMemory(diagnostics.currentMemorySample?.residentMB)
            )
            LabeledContent(
                "会话峰值",
                value: formattedMemory(
                    diagnostics.sessionPeakMemoryMB > 0
                        ? diagnostics.sessionPeakMemoryMB
                        : nil
                )
            )
            LabeledContent("最近内存采样", value: formattedMemorySampleDate)
            LabeledContent(
                "系统内存警告次数",
                value: "\(diagnostics.systemMemoryWarningCount)"
            )
            LabeledContent("WebView 终止次数", value: "\(diagnostics.processTerminationCount)")
            LabeledContent("最近终止时间", value: formattedTerminationDate)
            LabeledContent(
                "自动恢复超限次数",
                value: "\(diagnostics.recoveryLimitExceededCount)"
            )
            LabeledContent(
                "最近超限时终止次数",
                value: diagnostics.lastRecoveryLimitTerminationCount.map(String.init) ?? "无"
            )
            LabeledContent(
                "最近恢复超限时间",
                value: formattedDate(diagnostics.lastRecoveryLimitExceededAt)
            )
            LabeledContent(
                "Canvas → WebGL 降级次数",
                value: "\(diagnostics.canvasToWebGLFallbackCount)"
            )
            LabeledContent(
                "最近自动降级时间",
                value: formattedDate(diagnostics.lastCanvasToWebGLFallbackAt)
            )
            if !diagnostics.memorySamples.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近 App 内存样本")
                        .foregroundStyle(.secondary)
                    ForEach(Array(diagnostics.memorySamples.suffix(5).reversed())) { sample in
                        HStack {
                            Text(sample.date.formatted(date: .omitted, time: .standard))
                            Spacer()
                            Text(formattedMemory(sample.residentMB))
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            }
            LabeledContent("最近游戏端点", value: diagnostics.latestGameEndpoint ?? "无")
            LabeledContent("战斗 revision", value: "\(diagnostics.battleRevision)")
            LabeledContent("任务 revision", value: "\(diagnostics.questRevision)")
            LabeledContent("P3 warning", value: "\(diagnostics.p3WarningCount)")
            LabeledContent("评级偏差", value: "\(diagnostics.rankMismatchCount)")
            LabeledContent("P3 数据库", value: formattedDatabaseSize)
            if let latestError = diagnostics.navigationErrors.last {
                VStack(alignment: .leading, spacing: 5) {
                    Text("最近错误")
                        .foregroundStyle(.secondary)
                    Text(latestError)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                LabeledContent("最近错误", value: "无")
            }
            Text("以上 phys_footprint 仅属于 App 主进程。WebContent 运行在独立进程中，iOS 公开 API 无法读取其当前值或峰值。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        Section {
            Button("清除全部连接器登录凭证", role: .destructive) {
                confirmation = .clearCredentials
            }
        } header: {
            Text("隐私")
        } footer: {
            Text("删除 DMM、kancolle.moe 与 ooi.moe 在系统钥匙串中的账号密码。")
        }
    }

    private var versionSection: some View {
        Section("关于") {
            LabeledContent("版本", value: appVersion)
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .clearCache:
            return "确定清理全部游戏资源缓存？"
        case .clearCredentials:
            return "确定清除全部连接器的登录凭证？"
        case nil:
            return ""
        }
    }

    private var formattedTerminationDate: String {
        formattedDate(diagnostics.lastProcessTermination)
    }

    private var formattedMemorySampleDate: String {
        formattedDate(diagnostics.currentMemorySample?.date)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "无" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func formattedMemory(_ megabytes: Double?) -> String {
        guard let megabytes else { return "无" }
        return String(format: "%.1f MB", megabytes)
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var formattedDatabaseSize: String {
        ByteCountFormatter.string(
            fromByteCount: diagnostics.p3DatabaseSizeBytes,
            countStyle: .file
        )
    }

    private func update(_ mutation: (inout SettingsStore) -> Void) {
        var writableSettings = settings
        mutation(&writableSettings)
    }

    private func clearCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let root = FileManager.default.urls(
                        for: .cachesDirectory,
                        in: .userDomainMask
                    )[0].appendingPathComponent(
                        BrowserConstants.cacheDirName,
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: root,
                        withIntermediateDirectories: true
                    )
                    let versions = try VersionStore(
                        path: root.appendingPathComponent("versions.sqlite").path
                    )
                    try versions.removeAll()
                    let resources = root.appendingPathComponent(
                        "resources",
                        isDirectory: true
                    )
                    if FileManager.default.fileExists(atPath: resources.path) {
                        try FileManager.default.removeItem(at: resources)
                    }
                    URLCache.shared.removeAllCachedResponses()
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isClearingCache = false
        }
    }

    private func clearCredentials() {
        do {
            try keychain.deleteAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
