# P1 浏览器核心 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 iOS 上交付可实际游玩舰 C 的浏览器核心：连接器/登录/地区绕行、资源缓存、gadget 绕行、静音、截图、触摸补丁、字幕、白屏恢复 + 内存监测、悬浮球框架、设置页。

**架构：** SwiftUI 壳 + 单 WKWebView；纯逻辑放在本地 SPM 包 `Packages/GameCore`（用 `swift test` 在 Mac 上直接测试，不依赖 Xcode 工程）；UI/胶水代码在 App target（工程使用 PBXFileSystemSynchronizedRootGroup，向 `Game/` 目录添加文件即自动加入编译，无需改 pbxproj）。所有 WKWebView 流量经 `proxyConfigurations` 走 App 内嵌的本地 HTTP 代理（Network 框架）：CONNECT 隧道转发 HTTPS，明文 HTTP（kancolle-server.com 游戏资源）代理解析后可缓存/补丁/替换。

**技术栈：** Swift 5 / SwiftUI / WebKit (WKWebView, proxyConfigurations iOS 17+) / Network (NWListener) / SQLite3 C API / XCTest (swift test) / Photos（截图保存）。**约束（用户要求）：控件与 API 实现一律使用 Apple 原生 API，不引入第三方依赖；API 签名以 https://developer.apple.com/documentation 为准（实现时用 WebFetch 核对）。**

**关键背景知识（执行者必读）：**
- 参考源码：GotoBrowser = `/Users/haozhe/GitHub/GotoBrowser`，kcanotify = `/Users/haozhe/GitHub/kcanotify-master`。移植时以这些文件为准。
- 舰 C 游戏资源（`wXXg.kancolle-server.com`）是**明文 HTTP**（GotoBrowser `Constants.GADGET_HTTP_URL`、`usesCleartextTraffic=true` 可证）。DMM/osapi 页面是 HTTPS。
- `proxyConfigurations` 是 iOS 17+ API：`WKWebsiteDataStore.proxyConfigurations = [ProxyConfiguration.httpCONNECTRelay(...)]`（确切签名以编译器为准，实现时查 Apple 文档「ProxyConfiguration」）。
- iOS 17+ WKWebView 可能把 HTTPS 页面中的 HTTP 子资源自动升级为 HTTPS（导致代理看不到内容）——这是**任务 6 Spike 要验证的头号风险**。
- 工程当前 `IPHONEOS_DEPLOYMENT_TARGET = 26.5`，需降到 17.0。Bundle ID `KanColle.Game`。
- 构建验证命令（每个任务结束必须跑）：
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project /Users/haozhe/WorkTest/Game/Game.xcodeproj -scheme Game -destination 'generic/platform=iOS Simulator' build`
  逻辑包测试：`cd /Users/haozhe/WorkTest/Game/Packages/GameCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`（本机 xcode-select 指向 Command Line Tools，所有 swift test / xcodebuild 命令都必须带 DEVELOPER_DIR 前缀）

---

## 文件结构

```
Packages/GameCore/                       # 本地 SPM 包（纯逻辑，swift test 可测）
  Package.swift
  Sources/GameCore/
    BrowserConstants.swift               # URL/UA/JS 片段/拦截规则/pref 键（移植 Constants.java）
    SettingsStore.swift                  # UserDefaults 封装 + 全部设置键
    ProxyHTTPParser.swift                # HTTP 请求行/头部增量解析
    BlockRules.swift                     # 广告/追踪域名阻断
    LocalProxyServer.swift               # NWListener 代理：CONNECT 隧道 + HTTP 终止
    VersionStore.swift                   # SQLite3 资源版本表
    CachePolicy.swift                    # 缓存过期判定（Last-Modified/max-age）
    ResourceCache.swift                  # 缓存命中/回源/落盘
    AssetReplacer.swift                  # assets 内置资源替换（字体/维护页等）
    ScriptPatcher.swift                  # main.js 补丁（静音/触摸/截图/ADJUST/axios 拦截）
    SubtitleStore.swift                  # 字幕数据下载与缓存
    VoiceLineMatcher.swift               # 语音文件名→字幕匹配（移植 Kc3SubtitleProvider）
  Tests/GameCoreTests/
    SettingsStoreTests.swift
    ProxyHTTPParserTests.swift
    BlockRulesTests.swift
    CachePolicyTests.swift
    VersionStoreTests.swift
    ScriptPatcherTests.swift
    VoiceLineMatcherTests.swift
Game/                                    # App target（同步文件夹，加文件即入编译）
  GameApp.swift                          # 已存在，改为加载 RootView
  RootView.swift                         # 入口页/游戏页切换
  Entrance/EntranceView.swift            # 连接器选择 + 账号密码 + 设置入口
  Entrance/KeychainStore.swift           # DMM 凭证 Keychain 读写
  Entrance/LoginAutomation.swift         # 登录页检测/自动填充/ckcy cookie/OOI 登录
  Browser/BrowserView.swift              # WKWebView 的 UIViewRepresentable
  Browser/WebViewCoordinator.swift       # 导航代理/白屏恢复/JS 消息桥
  Browser/JSBridge.swift                 # WKScriptMessageHandler 集中分发
  Game/GameView.swift                    # 游戏画面 + 悬浮球 + 字幕条容器
  Game/FloatingBallView.swift            # 可拖动贴边悬浮球
  Game/FloatingMenuView.swift            # 悬浮球点开的菜单覆盖层（P1 仅设置/截图等）
  Capture/ScreenshotSaver.swift          # dataURL → 相册
  Subtitle/SubtitleBarView.swift         # 字幕条
  Health/MemoryMonitor.swift             # 内存采样 + 阈值告警
  Health/DiagnosticsStore.swift          # 白屏次数/内存采样记录
  Settings/SettingsView.swift            # 设置页
docs/superpowers/spike-results.md        # 任务 6 产物
```

---

### 任务 1：工程配置 + GameCore 包骨架

**文件：**
- 修改：`Game.xcodeproj/project.pbxproj`（部署目标 26.5 → 17.0，两处）
- 创建：`Packages/GameCore/Package.swift`、`Packages/GameCore/Sources/GameCore/Placeholder.swift`、`Packages/GameCore/Tests/GameCoreTests/PlaceholderTests.swift`
- 创建：`Game/Info.plist`（如工程尚无；Xcode 26 模板可能用 build settings 生成 Info.plist——先检查）

- [ ] **步骤 1：检查工程现状**

运行：
```bash
ls /Users/haozhe/WorkTest/Game/Game/
grep -n "INFOPLIST\|GENERATE_INFOPLIST" /Users/haozhe/WorkTest/Game/Game.xcodeproj/project.pbxproj
```
若存在 `GENERATE_INFOPLIST_FILE = YES`，Info.plist 由构建设置生成，权限键需加 `INFOPLIST_KEY_*` 到 pbxproj；若存在实体 Info.plist 则直接编辑。记录结论。

- [ ] **步骤 2：降部署目标到 17.0**

把 project.pbxproj 中两处 `IPHONEOS_DEPLOYMENT_TARGET = 26.5;` 改为 `IPHONEOS_DEPLOYMENT_TARGET = 17.0;`（用 Edit 工具）。

- [ ] **步骤 3：配置权限与 ATS**

若生成式 Info.plist：在 pbxproj 两处 target buildSettings 追加（与现有 INFOPLIST_KEY_* 条目并列）：
```
INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "保存游戏截图到相册";
INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
```
并在 target 的 `INFOPLIST_KEY_` 同区域加 App Transport Security——生成式 plist 不支持任意字典，故创建实体 `Game/Info.plist` 只放 ATS 不行（会冲突）。**统一做法**：把 `GENERATE_INFOPLIST_FILE = YES` 改为 `NO`，创建完整 `Game/Info.plist`：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>UILaunchScreen</key><dict/>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>NSPhotoLibraryAddUsageDescription</key><string>保存游戏截图到相册</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key><true/>
	</dict>
</dict>
</plist>
```
并在 pbxproj 两处 buildSettings 加 `INFOPLIST_FILE = Game/Info.plist;`，删除所有 `INFOPLIST_KEY_*` 行与 `GENERATE_INFOPLIST_FILE` 行。

- [ ] **步骤 4：创建 GameCore 包**

`Packages/GameCore/Package.swift`：
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GameCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GameCore", targets: ["GameCore"])],
    targets: [
        .target(name: "GameCore"),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"])
    ]
)
```
`Sources/GameCore/Placeholder.swift`：
```swift
public enum Placeholder { public static let ready = true }
```
`Tests/GameCoreTests/PlaceholderTests.swift`：
```swift
import XCTest
@testable import GameCore

final class PlaceholderTests: XCTestCase {
    func testReady() { XCTAssertTrue(Placeholder.ready) }
}
```

- [ ] **步骤 5：跑通包测试与 App 构建**

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore && swift test
```
预期：`Test Suite 'All tests' passed`。

- [ ] **步骤 6：把 GameCore 链接进 App target**

在 project.pbxproj 中：
1. `/* Begin XCLocalSwiftPackageReference section */`（不存在则在 PBXProject 段后新建）添加：
```
		<24位大写HEX> /* Packages/GameCore */ = {isa = XCLocalSwiftPackageReference; relativePath = Packages/GameCore; };
```
2. `/* Begin XCSwiftPackageProductDependency section */` 添加：
```
		<24位大写HEX> /* GameCore */ = {isa = XCSwiftPackageProductDependency; package = <上一步UUID> /* Packages/GameCore */; productName = GameCore; };
```
3. PBXBuildFile 段添加：
```
		<24位大写HEX> /* GameCore in Frameworks */ = {isa = PBXBuildFile; productRef = <步骤2 UUID> /* GameCore */; };
```
4. 把该 BuildFile UUID 加入 `PBXFrameworksBuildPhase` 的 `files` 列表。
5. 在 PBXNativeTarget `Game` 的 `packageProductDependencies`（无则新建）加 `<步骤2 UUID> /* GameCore */,`。
6. PBXProject 的 `knownRegions`/`mainGroup` 不动。
UUID 生成：`uuidgen | tr -d '-' | tr 'a-f' 'A-F' | cut -c1-24`。

**若手动编辑失败/构建报错**：请用户在 Xcode 中 File → Add Package Dependencies… → Add Local… 选择 `Packages/GameCore`，一次性完成（用户已知悉会有这一步）。

- [ ] **步骤 7：验证 App 构建**

在 `Game/GameApp.swift` 顶部加 `import GameCore` 并在 `init()` 加 `_ = Placeholder.ready`，跑：
```bash
xcodebuild -project /Users/haozhe/WorkTest/Game/Game.xcodeproj -scheme Game -destination 'generic/platform=iOS Simulator' build
```
预期：`BUILD SUCCEEDED`。（确认后这两行临时引用可保留，下个任务会真正使用 GameCore。）

- [ ] **步骤 8：Commit**

```bash
cd /Users/haozhe/WorkTest/Game && git add -A && git commit -m "chore: P1 工程配置——部署目标 17.0、Info.plist、GameCore 本地包"
```

---

### 任务 2：BrowserConstants + SettingsStore

**文件：**
- 创建：`Packages/GameCore/Sources/GameCore/BrowserConstants.swift`
- 创建：`Packages/GameCore/Sources/GameCore/SettingsStore.swift`
- 测试：`Packages/GameCore/Tests/GameCoreTests/SettingsStoreTests.swift`
- 参考：`/Users/haozhe/GitHub/GotoBrowser/app/src/main/java/com/antest1/gotobrowser/Constants.java`（完整移植）

- [ ] **步骤 1：编写失败测试**

```swift
import XCTest
@testable import GameCore

final class SettingsStoreTests: XCTestCase {
    func testDefaults() {
        let s = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        XCTAssertEqual(s.connector, .dmm)
        XCTAssertTrue(s.cacheEnabled)
        XCTAssertFalse(s.silentStart)
        XCTAssertFalse(s.alterGadget)
        XCTAssertEqual(s.subtitleFontSize, 18)
        XCTAssertEqual(s.cursorMode, .touch)
    }
    func testRoundTrip() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        var s = SettingsStore(defaults: d)
        s.connector = .ooi
        s.silentStart = true
        let s2 = SettingsStore(defaults: d)
        XCTAssertEqual(s2.connector, .ooi)
        XCTAssertTrue(s2.silentStart)
    }
    func testBlockRulesPorted() {
        XCTAssertTrue(BrowserConstants.blockRules.contains("doubleclick.net"))
        XCTAssertEqual(BrowserConstants.blockRules.count, 7)
    }
    func testUAStrings() {
        XCTAssertTrue(BrowserConstants.userAgentDesktop.contains("Chrome/142.0.0.0"))
        XCTAssertTrue(BrowserConstants.userAgentIOSCanvas.contains("Safari/605.1.15"))
        XCTAssertTrue(BrowserConstants.userAgentMobile.contains("Mobile Safari/537.36"))
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore && swift test --filter SettingsStoreTests
```
预期：编译错误 `cannot find 'SettingsStore' in scope`。

- [ ] **步骤 3：实现 BrowserConstants.swift**

完整移植 Constants.java 的 URL、UA、JS 片段（ADJUST_SCRIPT / MUTE_SEND / MUTE_LISTEN / CAPTURE_SEND / CAPTURE_LISTEN / DMM_COOKIE / AUTOCOMPLETE / ADD_VIEWPORT_META）、blockRules、GADGET 相关常量、CACHE_DIR。结构：
```swift
public enum BrowserConstants {
    public static let cacheDirName = "browser_cache"

    public enum Connector: String, CaseIterable, Sendable {
        case dmm = "DMM direct"
        case kanmoe = "kancolle.moe"
        case ooi = "ooi.moe"
        public var url: URL {
            switch self {
            case .dmm: return URL(string: "https://play.games.dmm.com/game/kancolle")!
            case .kanmoe: return URL(string: "https://kancolle.moe/")!
            case .ooi: return URL(string: "https://ooi.moe/")!
            }
        }
        public var logoutURL: URL {
            switch self {
            case .dmm: return URL(string: "https://www.dmm.com/my/-/login/logout/=/path=Sg9VTQFXDFcXFl5bWlcKGExKUVdUXgFNEU0KSVMVR28MBQ0BUwJZBwxK")!
            case .kanmoe: return URL(string: "https://kancolle.moe/logout")!
            case .ooi: return URL(string: "https://ooi.moe/logout")!
            }
        }
    }

    public static let userAgentDesktop = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
    public static let userAgentIOSCanvas = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    public static let userAgentMobile = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36"

    public static let blockRules = [
        "twitter.com/i/jot", "dmm.com/latest/js/dmm.tracking", "doubleclick.net",
        "googletagmanager.com/", "facebook.com", "pics.dmm.com/", "/uikit"
    ]

    public static let gadgetOsapiIfr = "osapi.dmm.com/gadgets/ifr?aid=854854"
    public static let gadgetHTTPHost = "w00g.kancolle-server.com"
    public static let defaultAlterGadgetURL = "https://kcwiki.github.io/cache/"

    public static let dmmLoginMarkers = ["www.dmm.com/my/-/login/", "accounts.dmm.com/service/login/password"]
    public static let dmmForeignMarkers = ["www.dmm.com/netgame/foreign", "special.dmm.com/not-available-in-your-region"]

    // JS 片段：从 Constants.java 逐字拷贝（ADJUST_SCRIPT、MUTE_LISTEN、CAPTURE_LISTEN、
    // MUTE_SEND_DMM/OOI、CAPTURE_SEND_DMM/OOI、AUTOCOMPLETE_DMM/OOI、ADD_VIEWPORT_META、DMM_COOKIE）
    public static let adjustScript = #"..."#   // Constants.java:127 逐字
    public static let muteListen = #"..."#       // Constants.java:121 逐字
    public static let captureListen = #"..."#    // Constants.java:125 逐字，但把
    //   GotoBrowser.kcs_process_canvas_dataurl(dataurl)
    //   改为 window.webkit.messageHandlers.gotoBrowser.postMessage({type:"capture", data:dataurl})
    // ……其余片段同法移植
}
```
注意：`CAPTURE_LISTEN` 中的 `GotoBrowser.xxx` Android 桥调用全部改为 `window.webkit.messageHandlers.gotoBrowser.postMessage({...})` 形式（统一桥，JSBridge 按 `type` 分发）。

- [ ] **步骤 4：实现 SettingsStore.swift**

```swift
import Foundation

public struct SettingsStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public enum CursorMode: String { case touch = "1", mouse = "2" }

    public var connector: BrowserConstants.Connector {
        get { BrowserConstants.Connector(rawValue: defaults.string(forKey: "pref_connector") ?? "") ?? .dmm }
        set { defaults.set(newValue.rawValue, forKey: "pref_connector") }
    }
    public var cacheEnabled: Bool { get { defaults.object(forKey: "pref_cache") as? Bool ?? true } set { defaults.set(newValue, forKey: "pref_cache") } }
    public var silentStart: Bool { get { defaults.bool(forKey: "pref_silent") } set { defaults.set(newValue, forKey: "pref_silent") } }
    public var muteMode: Bool { get { defaults.bool(forKey: "pref_mutemode") } set { defaults.set(newValue, forKey: "pref_mutemode") } }
    public var alterGadget: Bool { get { defaults.bool(forKey: "pref_alter_gadget") } set { defaults.set(newValue, forKey: "pref_alter_gadget") } }
    public var alterGadgetEndpoint: String { get { defaults.string(forKey: "pref_alter_endpoint") ?? BrowserConstants.defaultAlterGadgetURL } set { defaults.set(newValue, forKey: "pref_alter_endpoint") } }
    public var legacyRenderer: Bool { get { defaults.object(forKey: "pref_legacy_renderer") as? Bool ?? true } set { defaults.set(newValue, forKey: "pref_legacy_renderer") } }  // 规格：iPhone 默认 Canvas
    public var subtitleLocale: String { get { defaults.string(forKey: "pref_subtitle_locale") ?? "scn" } set { defaults.set(newValue, forKey: "pref_subtitle_locale") } }
    public var subtitleEnabled: Bool { get { defaults.bool(forKey: "pref_showcc") } set { defaults.set(newValue, forKey: "pref_showcc") } }
    public var subtitleFontSize: Int { get { defaults.object(forKey: "pref_subtitle_size") as? Int ?? 18 } set { defaults.set(newValue, forKey: "pref_subtitle_size") } }
    public var cursorMode: CursorMode { get { CursorMode(rawValue: defaults.string(forKey: "pref_cursor_mode") ?? "1") ?? .touch } set { defaults.set(newValue.rawValue, forKey: "pref_cursor_mode") } }
    public var keepScreenOn: Bool { get { defaults.bool(forKey: "pref_keepmode") } set { defaults.set(newValue, forKey: "pref_keepmode") } }
    public var downloadRetry: Bool { get { defaults.object(forKey: "pref_retry") as? Bool ?? true } set { defaults.set(newValue, forKey: "pref_retry") } }
    public var memoryWarnEnabled: Bool { get { defaults.object(forKey: "pref_mem_warn") as? Bool ?? true } set { defaults.set(newValue, forKey: "pref_mem_warn") } }
    public var memoryWarnThresholdMB: Int { get { defaults.object(forKey: "pref_mem_warn_mb") as? Int ?? 0 } set { defaults.set(newValue, forKey: "pref_mem_warn_mb") } } // 0 = 自动(设备RAM 40%)
    public var latestURL: String? { get { defaults.string(forKey: "pref_latest_url") } set { defaults.set(newValue, forKey: "pref_latest_url") } }
}
```

- [ ] **步骤 5：运行测试验证通过**

`swift test --filter SettingsStoreTests` 预期全 PASS。

- [ ] **步骤 6：Commit**

`git add -A && git commit -m "feat(core): BrowserConstants 与 SettingsStore（移植 GotoBrowser 常量与设置键）"`

---

### 任务 3：ProxyHTTPParser + BlockRules

**文件：**
- 创建：`Packages/GameCore/Sources/GameCore/ProxyHTTPParser.swift`
- 创建：`Packages/GameCore/Sources/GameCore/BlockRules.swift`
- 测试：`Packages/GameCore/Tests/GameCoreTests/ProxyHTTPParserTests.swift`、`BlockRulesTests.swift`

- [ ] **步骤 1：编写失败测试**

```swift
final class ProxyHTTPParserTests: XCTestCase {
    func testParseGetRequest() {
        var p = ProxyHTTPParser()
        let raw = "GET /kcs2/resources/ship/full/0001.png?ver=3 HTTP/1.1\r\nHost: w01g.kancolle-server.com\r\nAccept: */*\r\n\r\n"
        let result = p.feed(Data(raw.utf8))
        guard case .request(let req) = result else { return XCTFail() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/kcs2/resources/ship/full/0001.png?ver=3")
        XCTAssertEqual(req.host, "w01g.kancolle-server.com")
        XCTAssertEqual(req.header("accept"), "*/*")
    }
    func testParseConnect() {
        var p = ProxyHTTPParser()
        let raw = "CONNECT play.games.dmm.com:443 HTTP/1.1\r\nHost: play.games.dmm.com:443\r\n\r\n"
        guard case .connect(let host, let port) = p.feed(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(host, "play.games.dmm.com")
        XCTAssertEqual(port, 443)
    }
    func testIncrementalFeed() {
        var p = ProxyHTTPParser()
        XCTAssertEqual(p.feed(Data("GET /a".utf8)), .needMore)
        let rest = " HTTP/1.1\r\nHost: x.com\r\n\r\n"
        guard case .request = p.feed(Data(rest.utf8)) else { return XCTFail() }
    }
}

final class BlockRulesTests: XCTestCase {
    func testBlocked() {
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://pagead2.googlesyndication.com/x"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://www.dmm.com/latest/js/dmm.tracking.js"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://osapi.dmm.com/uikit/js/x.js"))
    }
    func testAllowed() {
        XCTAssertFalse(BlockRules.isBlocked(urlString: "http://w01g.kancolle-server.com/kcs2/js/main.js"))
        XCTAssertFalse(BlockRules.isBlocked(urlString: "https://play.games.dmm.com/game/kancolle"))
    }
}
```

- [ ] **步骤 2：运行验证失败**（`swift test --filter ProxyHTTPParserTests`，编译错误）

- [ ] **步骤 3：实现 ProxyHTTPParser.swift**

```swift
import Foundation

public struct ProxyHTTPParser {
    public enum ParseResult: Equatable {
        case needMore
        case request(HTTPRequestHead)
        case connect(host: String, port: Int)
        case invalid
    }
    public struct HTTPRequestHead: Equatable {
        public let method: String
        public let path: String           // 原始 path（含 query）
        public let host: String           // Host 头（去端口）
        public let port: Int
        public let headers: [(String, String)]
        public func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    private var buffer = Data()
    public init() {}

    public mutating func feed(_ data: Data) -> ParseResult {
        buffer.append(data)
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid : .needMore
        }
        let headData = buffer.subdata(in: 0..<range.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [(String, String)] = []
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<i]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)))
        }
        if method.uppercased() == "CONNECT" {
            let hp = target.split(separator: ":")
            guard let h = hp.first else { return .invalid }
            return .connect(host: String(h), port: hp.count > 1 ? Int(hp[1]) ?? 443 : 443)
        }
        // 普通请求：target 可能是绝对 URI（代理形式）或 path
        var host = headers.first { $0.0.lowercased() == "host" }?.1 ?? ""
        var port = 80
        if let i = host.firstIndex(of: ":") { port = Int(host[host.index(after: i)...]) ?? 80; host = String(host[..<i]) }
        var path = target
        if target.lowercased().hasPrefix("http://"), let u = URL(string: target) {
            host = u.host ?? host
            port = u.port ?? 80
            path = u.path + (u.query.map { "?" + $0 } ?? "")
        }
        guard !host.isEmpty else { return .invalid }
        return .request(HTTPRequestHead(method: method, path: path, host: host, port: port, headers: headers))
    }
}
```

- [ ] **步骤 4：实现 BlockRules.swift**

```swift
import Foundation

public enum BlockRules {
    public static func isBlocked(urlString: String) -> Bool {
        BrowserConstants.blockRules.contains { urlString.contains($0) }
    }
    public static func isBlocked(host: String) -> Bool {
        // CONNECT 场景只有 host：匹配包含 host 的规则片段
        ["doubleclick.net", "googletagmanager.com", "facebook.com"].contains { host.contains($0) }
    }
}
```

- [ ] **步骤 5：运行验证通过** → `swift test` 全 PASS

- [ ] **步骤 6：Commit** — `git commit -m "feat(core): HTTP 代理解析器与广告阻断规则"`

---

### 任务 4：LocalProxyServer（CONNECT 隧道 + HTTP 终止）

**文件：**
- 创建：`Packages/GameCore/Sources/GameCore/LocalProxyServer.swift`
- 手动验证：curl 走代理

- [ ] **步骤 1：实现 LocalProxyServer.swift**

职责：NWListener 监听 127.0.0.1 随机端口；每连接先跑 ProxyHTTPParser；按结果分流——
- `.connect(host, 443)` 或被阻断 host：阻断则回 `HTTP/1.1 403` 关连接；否则回 `HTTP/1.1 200 Connection Established` 后双向透传（NWConnection 到 host:443）。
- `.connect(host, 80)` 或 `.request`：进入**游戏资源模式**——本轮先不做缓存（任务 8 接入），直接转发到 host:80 并把响应原样回传，但要把「请求+响应头+状态码」通过回调抛给上层日志。
- 回调接口：`public var onRequest: ((ProxyRequestLog) -> Void)?`、`public var onGameResourceRequest: ((ProxyHTTPParser.HTTPRequestHead) -> ResourceResponse?)?`（任务 8 用；返回 nil = 回源转发）。

```swift
import Foundation
import Network

public struct ProxyRequestLog: Sendable {
    public let host: String
    public let path: String
    public let statusCode: Int?
    public let blocked: Bool
}

/// 资源响应（任务 8 的缓存/替换层返回；本任务定义类型）
public struct ResourceResponse: Sendable {
    public var statusCode: Int
    public var headers: [(String, String)]
    public var body: Data
    public init(statusCode: Int, headers: [(String, String)], body: Data) {
        self.statusCode = statusCode; self.headers = headers; self.body = body
    }
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Not Found")\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

public final class LocalProxyServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public var onRequest: ((ProxyRequestLog) -> Void)?
    public var onGameResourceRequest: ((ProxyHTTPParser.HTTPRequestHead) -> ResourceResponse?)?
    /// 判定该 host 是否走「内容可见」模式（默认 kancolle-server.com:80）
    public var isInspectableHost: ((String, Int) -> Bool) = { host, port in
        port == 80 && host.hasSuffix("kancolle-server.com")
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "localproxy", attributes: .concurrent)

    public init() {}

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = l.port?.rawValue ?? 0 }
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data else { conn.cancel(); return }
            var parser = ProxyHTTPParser()
            switch parser.feed(data) {
            case .connect(let host, let port):
                if BlockRules.isBlocked(host: host) {
                    self.reply(conn, bytes: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8)) { conn.cancel() }
                    self.onRequest?(ProxyRequestLog(host: host, path: "", statusCode: 403, blocked: true))
                } else if self.isInspectableHost(host, port) {
                    // :80 CONNECT（少见）：回 200 后按 HTTP 终止模式处理
                    self.reply(conn, bytes: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) {
                        self.serveHTTP(conn, host: host, port: port)
                    }
                } else {
                    self.tunnel(conn, host: host, port: port)
                }
            case .request(let head):
                if BlockRules.isBlocked(urlString: "http://\(head.host)\(head.path)") {
                    self.reply(conn, bytes: ResourceResponse(statusCode: 200, headers: [("Content-Type","text/plain")], body: Data()).serialized()) { conn.cancel() }
                    self.onRequest?(ProxyRequestLog(host: head.host, path: head.path, statusCode: 200, blocked: true))
                } else {
                    self.serveHTTPRequest(conn, head: head)
                }
            case .needMore:
                // 继续收（简化：重入 receive 直到拿到完整头；实现时循环 receive 累积到 parser 产出结果）
                self.handleStreaming(conn, parser: parser, initial: data)
            case .invalid:
                conn.cancel()
            }
        }
    }

    // 头部跨包到达时累积解析
    private func handleStreaming(_ conn: NWConnection, parser: ProxyHTTPParser, initial: Data) {
        var parser = parser
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data else { conn.cancel(); return }
            switch parser.feed(data) {
            case .needMore: self.handleStreaming(conn, parser: parser, initial: initial)
            case .connect(let host, let port): self.tunnel(conn, host: host, port: port)
            case .request(let head): self.serveHTTPRequest(conn, head: head)
            case .invalid: conn.cancel()
            }
        }
    }

    private func tunnel(_ client: NWConnection, host: String, port: Int) {
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        upstream.start(queue: queue)
        reply(client, bytes: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) { [weak self] in
            guard let self else { return }
            self.pump(client, to: upstream)
            self.pump(upstream, to: client)
        }
    }

    private func pump(_ from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, _ in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete { to.cancel(); from.cancel() } else { self?.pump(from, to: to) }
        }
    }

    private func serveHTTP(_ conn: NWConnection, host: String, port: Int) {
        // CONNECT 到 :80 之后的第一个真实请求
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data else { conn.cancel(); return }
            var parser = ProxyHTTPParser()
            if case .request(let head) = parser.feed(data) {
                self.serveHTTPRequest(conn, head: head)
            } else { conn.cancel() }
        }
    }

    private func serveHTTPRequest(_ client: NWConnection, head: ProxyHTTPParser.HTTPRequestHead) {
        if let local = onGameResourceRequest?(head) {
            reply(client, bytes: local.serialized()) { client.cancel() }
            onRequest?(ProxyRequestLog(host: head.host, path: head.path, statusCode: local.statusCode, blocked: false))
            return
        }
        // 回源：重建请求（Connection: close），读完整响应回传
        let upstream = NWConnection(host: NWEndpoint.Host(head.host), port: NWEndpoint.Port(rawValue: UInt16(head.port))!, using: .tcp)
        upstream.start(queue: queue)
        var request = "\(head.method) \(head.path) HTTP/1.1\r\n"
        for (k, v) in head.headers where k.lowercased() != "connection" && k.lowercased() != "proxy-connection" {
            request += "\(k): \(v)\r\n"
        }
        request += "Connection: close\r\n\r\n"
        upstream.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        var received = Data()
        func drain() {
            upstream.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, _ in
                guard let self else { return }
                if let data { received.append(data) }
                if isComplete {
                    let status = Self.statusCode(of: received)
                    self.reply(client, bytes: received) { client.cancel(); upstream.cancel() }
                    self.onRequest?(ProxyRequestLog(host: head.host, path: head.path, statusCode: status, blocked: false))
                } else { drain() }
            }
        }
        drain()
    }

    static func statusCode(of response: Data) -> Int? {
        guard let s = String(data: response.prefix(15), encoding: .utf8) else { return nil }
        let parts = s.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) : nil
    }

    private func reply(_ conn: NWConnection, bytes: Data, then: @escaping () -> Void) {
        conn.send(content: bytes, completion: .contentProcessed { _ in then() })
    }
}
```
说明：P1 按「每请求一连接（Connection: close）」实现，简单可靠；keep-alive 优化不在 P1 范围。

- [ ] **步骤 2：xcodebuild 构建验证**（包随 App 编译）+ `swift test` 不回归

- [ ] **步骤 3：curl 手动验证**

写一个临时可执行验证（或直接用下文任务 5 的 App 起代理后用 curl 验证；本步骤二选一，先选 curl 直连验证服务器逻辑——在 `swift test` 中加集成测试 `LocalProxyIntegrationTests`：启动 LocalProxyServer，用 URLSession 走 `http://127.0.0.1:<port>` 请求一个本地 NWListener 假上游，断言透传与状态码）：
```swift
final class LocalProxyIntegrationTests: XCTestCase {
    func testPlainHTTPForwarding() throws {
        // 假上游：起 NWListener 返回固定响应
        // 代理：start()，onGameResourceRequest 返回 nil（强制回源）
        // URLSession 请求 http://127.0.0.1:proxyPort/... —— URLSession 不支持显式代理到 localhost 走 CONNECT 语义，
        // 故直接 NWConnection 发 "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" 到代理端口，断言收到 200 与固定 body
    }
    func testBlockedHost() throws { /* CONNECT doubleclick.net:443 → 断言 403 */ }
}
```
（测试完整实现由执行者按上述注释补全，断言点已给出。）

- [ ] **步骤 4：Commit** — `git commit -m "feat(core): 本地代理服务器（CONNECT 隧道 + HTTP 终止 + 阻断）"`

---

### 任务 5：WebView 基础（BrowserView + Coordinator + 代理挂载）

**文件：**
- 创建：`Game/Browser/BrowserView.swift`
- 创建：`Game/Browser/WebViewCoordinator.swift`
- 创建：`Game/Browser/JSBridge.swift`
- 修改：`Game/GameApp.swift`（临时：RootView 先直接显示 BrowserView 加载连接器 URL，供任务 6 Spike 用）

- [ ] **步骤 1：实现 JSBridge.swift**

```swift
import WebKit

/// 统一消息桥：页面内 window.webkit.messageHandlers.gotoBrowser.postMessage({type:..., ...})
final class JSBridge: NSObject, WKScriptMessageHandler {
    enum Event {
        case capture(dataURL: String)
        case kcsapi(endpoint: String, request: String?, response: String)
        case apiError(code: Int)
        case memoryReport(jsHeapMB: Double)
        case log(String)
    }
    var onEvent: (Event) -> Void = { _ in }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let dict = m.body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "capture":
            if let d = dict["data"] as? String { onEvent(.capture(dataURL: d)) }
        case "kcsapi":
            onEvent(.kcsapi(endpoint: dict["endpoint"] as? String ?? "",
                            request: dict["request"] as? String,
                            response: dict["response"] as? String ?? ""))
        case "apiError":
            onEvent(.apiError(code: dict["code"] as? Int ?? 0))
        case "memory":
            onEvent(.memoryReport(jsHeapMB: dict["jsHeapMB"] as? Double ?? 0))
        default:
            onEvent(.log(String(describing: m.body)))
        }
    }
}
```

- [ ] **步骤 2：实现 BrowserView.swift（UIViewRepresentable）**

要点：
- `WKWebViewConfiguration`：`allowsInlineMediaPlayback = true`、`mediaTypesRequiringUserActionForPlayback = []`、preference 允许 JS 开窗不需要；`websiteDataStore.proxyConfigurations` 挂本地代理（任务 4 的端口）。
- 注入 `WKUserScript`（documentStart）：`ADD_VIEWPORT_META` + 内存上报探针：
```js
setInterval(function(){try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.gotoBrowser){var m=(performance&&performance.memory)?performance.memory.usedJSHeapSize/1048576:0;window.webkit.messageHandlers.gotoBrowser.postMessage({type:"memory",jsHeapMB:m});}}catch(e){}},10000);
```
- `customUserAgent` 按 `SettingsStore.legacyRenderer` 选 desktop/iOS Canvas UA。
- Coordinator 实现 `webViewWebContentProcessDidTerminate` → 记录 + `webView.reload()`；`didFailNavigation`/`didFailProvisionalNavigation` 日志。

```swift
import SwiftUI
import WebKit
import GameCore

struct BrowserView: UIViewRepresentable {
    let url: URL
    let proxyPort: UInt16
    var settings: SettingsStore
    let bridge: JSBridge

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if proxyPort > 0 {
            // iOS 17+：全部 WebView 流量走本地代理（确切 API 名以编译器为准）
            let relayURL = URL(string: "http://127.0.0.1:\(proxyPort)")!
            let relay = ProxyConfiguration.Relay.httpConnectProxy(relayURL)
            config.websiteDataStore.proxyConfigurations = [ProxyConfiguration.httpCONNECTRelay(relay)]
        }
        let probe = WKUserScript(source: BrowserConstants.viewportMetaScript + BrowserConstants.memoryProbeScript,
                                 injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(probe)
        config.userContentController.add(bridge, name: "gotoBrowser")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = settings.legacyRenderer ? BrowserConstants.userAgentIOSCanvas : BrowserConstants.userAgentDesktop
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.bounces = false
        wv.isOpaque = true
        context.coordinator.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}
```
（`BrowserConstants.viewportMetaScript` / `memoryProbeScript` 在任务 2 的常量文件中补齐——若任务 2 漏了，回本文件补。）

- [ ] **步骤 3：实现 WebViewCoordinator.swift**

```swift
import WebKit

final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    var onProcessTerminated: (() -> Void)?
    var onNavigation: ((URL?) -> Void)?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagnosticsStore.shared.recordProcessTermination()
        webView.reload()
        onProcessTerminated?()
    }
    func webView(_ wv: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { onNavigation?(wv.url) }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        DiagnosticsStore.shared.recordNavigationError(e.localizedDescription)
    }
}
```
（`DiagnosticsStore` 在任务 14 完整实现；本任务先建最小版：`recordProcessTermination()`/`recordNavigationError(_:)` 两个静态计数，避免后向引用编译失败。）

- [ ] **步骤 4：临时 RootView 供 Spike**

```swift
// Game/RootView.swift
import SwiftUI
import GameCore

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
            // 等 listener ready（轮询 port != 0，最长 2s）
            Task {
                for _ in 0..<20 where proxy.port == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
                started = true
            }
        }
    }
}
```
`GameApp.swift` 的 `ContentView()` 改为 `RootView()`，删除 `ContentView.swift`。

- [ ] **步骤 5：xcodebuild 构建验证** → BUILD SUCCEEDED

- [ ] **步骤 6：Commit** — `git commit -m "feat(browser): WKWebView 基础层（代理挂载/UA/白屏恢复/JS 桥）"`

---

### 任务 6：技术验证 Spike（手动，阻塞后续任务）

**目的：** 在真实游戏流量上验证架构假设，产物 `docs/superpowers/spike-results.md`。

- [ ] **步骤 1：给代理接日志面板**

临时在 RootView 加一个半透明日志 Text 区，把 `proxy.onRequest` 的 host+path+status 滚动显示（50 行上限）。同时在 `onGameResourceRequest` 里先返回 nil（纯回源），只记录。

- [ ] **步骤 2：模拟器/真机跑 App，逐项验证并记录**

| # | 验证项 | 通过标准 |
|---|---|---|
| 1 | 代理接管流量 | 日志出现 dmm.com 等域名的 CONNECT/请求记录 |
| 2 | DMM 登录页可达 | 页面正常渲染（不需要真登录，OOI 可用测试账号登录则更好） |
| 3 | 游戏资源明文可见 | 进入游戏后日志出现 `wXXg.kancolle-server.com` 的 HTTP 请求（非 CONNECT:443） |
| 4 | http→https 自动升级 | 若验证 3 失败且日志出现 kancolle-server.com 的 CONNECT 443，则确认升级发生 |
| 5 | main.js 可被代理改写 | 在 onGameResourceRequest 中对 main.js 回源后追加 `;window.__SPIKE_PATCHED=1;`，进游戏后在 JS 侧能读到（用日志探针回传） |
| 6 | axios 拦截可用 | 注入 KC3 式 XHR/fetch hook 脚本，游戏内母港加载后收到 `kcsapi` 消息（api_port） |
| 7 | 混合内容 | HTTPS 页面加载 HTTP 子资源无阻断（验证 3 通过即此项通过） |
| 8 | 长时间内存 | 游玩/挂机 15 分钟，记录 WebContent 是否被杀、内存曲线 |

- [ ] **步骤 3：写 spike-results.md 并据此决策**

- 若验证 3 通过 → 按原计划继续（内容级操作在代理层）。
- 若验证 3 失败（升级 https）→ 采用回退方案 B：main.js 补丁把资源 host 改写为 `http://127.0.0.1:<port>`（代理对 loopback HTTP 全可见），并实测 WKWebView 混合内容行为；若混合内容被阻断，再评估 WKURLSchemeHandler 改写方案。**把结论与方案变更写进 spike-results.md，并同步更新设计规格 §5.1**（用户确认后）。

- [ ] **步骤 4：Commit** — `git commit -m "docs: P1 技术验证 Spike 结果"`

---

### 任务 7：VersionStore + CachePolicy

**文件：**
- 创建：`Packages/GameCore/Sources/GameCore/VersionStore.swift`
- 创建：`Packages/GameCore/Sources/GameCore/CachePolicy.swift`
- 测试：`VersionStoreTests.swift`、`CachePolicyTests.swift`
- 参考：GotoBrowser `VersionDatabase.java`、`ResourceProcess.processImageDataResource` 的过期逻辑

- [ ] **步骤 1：编写失败测试**

```swift
final class VersionStoreTests: XCTestCase {
    func testSetGet() throws {
        let path = NSTemporaryDirectory() + "vstore-\(UUID().uuidString).db"
        let vs = try VersionStore(path: path)
        try vs.put(key: "/kcs2/js/main.js", version: "12345", lastModified: "Wed, 01 Jan 2025 00:00:00 GMT", maxAgeSeconds: 3600)
        let row = try vs.get(key: "/kcs2/js/main.js")
        XCTAssertEqual(row?.version, "12345")
        XCTAssertEqual(row?.maxAgeSeconds, 3600)
    }
    func testOverwrite() throws {
        let path = NSTemporaryDirectory() + "vstore-\(UUID().uuidString).db"
        let vs = try VersionStore(path: path)
        try vs.put(key: "a", version: "1", lastModified: nil, maxAgeSeconds: nil)
        try vs.put(key: "a", version: "2", lastModified: nil, maxAgeSeconds: nil)
        XCTAssertEqual(try vs.get(key: "a")?.version, "2")
    }
}

final class CachePolicyTests: XCTestCase {
    func testFreshByMaxAge() {
        let now = Date()
        let entry = CachePolicy.Entry(fetchedAt: now.addingTimeInterval(-100), lastModified: nil, maxAgeSeconds: 3600)
        XCTAssertTrue(CachePolicy.isFresh(entry, at: now))
    }
    func testExpiredNeedsRevalidate() {
        let now = Date()
        let entry = CachePolicy.Entry(fetchedAt: now.addingTimeInterval(-7200), lastModified: "x", maxAgeSeconds: 3600)
        XCTAssertFalse(CachePolicy.isFresh(entry, at: now))
    }
    func testParseCacheControlMaxAge() {
        XCTAssertEqual(CachePolicy.parseMaxAge("public, max-age=86400"), 86400)
        XCTAssertNil(CachePolicy.parseMaxAge("no-cache"))
    }
}
```

- [ ] **步骤 2：运行验证失败**（编译错误）

- [ ] **步骤 3：实现 VersionStore.swift（SQLite3 C API 薄封装）**

```swift
import Foundation
import SQLite3

public struct VersionRow: Equatable {
    public let key: String
    public let version: String?
    public let lastModified: String?
    public let maxAgeSeconds: Int?
    public let fetchedAt: Date
}

public final class VersionStore {
    private var db: OpaquePointer?
    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK { throw NSError(domain: "VersionStore", code: 1) }
        try exec("CREATE TABLE IF NOT EXISTS version_table (KEY TEXT PRIMARY KEY, VERSION TEXT, LAST_MODIFIED TEXT, MAX_AGE INTEGER, FETCHED_AT REAL)")
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw NSError(domain: "VersionStore", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
    }
    public func put(key: String, version: String?, lastModified: String?, maxAgeSeconds: Int?) throws {
        let sql = "INSERT OR REPLACE INTO version_table (KEY, VERSION, LAST_MODIFIED, MAX_AGE, FETCHED_AT) VALUES (?,?,?,?,?)"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        bindText(stmt, 2, version); bindText(stmt, 3, lastModified)
        if let m = maxAgeSeconds { sqlite3_bind_int64(stmt, 4, m) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }
    public func get(key: String) throws -> VersionRow? {
        let sql = "SELECT KEY, VERSION, LAST_MODIFIED, MAX_AGE, FETCHED_AT FROM version_table WHERE KEY = ?"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return VersionRow(key: key,
                          version: columnText(stmt, 1), lastModified: columnText(stmt, 2),
                          maxAgeSeconds: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3)),
                          fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))
    }
    public func removeAll() throws { try exec("DELETE FROM version_table") }
    private func bindText(_ s: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(s, i, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } else { sqlite3_bind_null(s, i) }
    }
    private func columnText(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
}
```

- [ ] **步骤 4：实现 CachePolicy.swift**

```swift
import Foundation

public enum CachePolicy {
    public struct Entry: Equatable {
        public let fetchedAt: Date
        public let lastModified: String?
        public let maxAgeSeconds: Int?
    }
    public static func isFresh(_ e: Entry, at now: Date) -> Bool {
        guard let maxAge = e.maxAgeSeconds else { return false }
        return now.timeIntervalSince(e.fetchedAt) < TimeInterval(maxAge)
    }
    public static func parseMaxAge(_ cacheControl: String?) -> Int? {
        guard let cc = cacheControl else { return nil }
        for part in cc.split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=")
            if kv.count == 2, kv[0].lowercased() == "max-age" { return Int(kv[1]) }
        }
        return nil
    }
}
```

- [ ] **步骤 5：运行验证通过** → `swift test` 全 PASS

- [ ] **步骤 6：Commit** — `git commit -m "feat(core): 资源版本表与缓存过期策略"`

---

### 任务 8：ResourceCache + AssetReplacer + 代理集成 + gadget 绕行

**文件：**
- 创建：`Packages/GameCore/Sources/GameCore/ResourceCache.swift`
- 创建：`Packages/GameCore/Sources/GameCore/AssetReplacer.swift`
- 修改：`Packages/GameCore/Sources/GameCore/LocalProxyServer.swift`（接 onGameResourceRequest 默认实现）
- 复制资源：GotoBrowser `app/src/main/assets/` 中的 `A-OTF-UDShinGoPro-*.woff2`、`maintenance.png/html`、`tweenjs-0.6.2.min.js`、`rollover.js`、`kcs_cda.js`、`ooi.css`、`touch_event_patch.js`、`game_custom.css`、`dmm_custom.css` → `Game/BundleAssets/`（App target bundle 资源，同步文件夹自动打包）
- 参考：`ResourceProcess.java`（分类位标志、processImageDataResource/processAudioFile/getFontFile/getMaintenanceFiles、gadget 替换逻辑）

- [ ] **步骤 1：实现 ResourceCache.swift（含测试）**

职责：给定 `HTTPRequestHead` → 返回 `ResourceResponse?`。
判定流程（移植 ResourceProcess.processWebRequest 的顺序）：
1. `AssetReplacer.replacement(forPath:)` 命中 → 返回内置资源（字体/维护页/tweenjs/rollover/kcs_cda）。
2. 非游戏资源 host（非 `*.kancolle-server.com`）→ nil（回源透传）。
3. gadget 绕行开启且 path 命中 gadget 脚本路径 → 上游改为 `alterGadgetEndpoint` 下载（移植 `replaceEndpoint` 的映射规则，源：`ResourceProcess.java` 中 `alter_gadget` 相关分支）。
4. 缓存命中且 `CachePolicy.isFresh` → 读盘返回。
5. 缓存过期但有 Last-Modified → 回源带 `If-Modified-Since`；304 → 更新 fetchedAt 返回旧文件；200 → 落盘更新版本表。
6. 无缓存 → 回源下载、落盘、更新版本表（version 取 URL query 的 ver 参数）。
下载用 `URLSession.shared` 同步包装（`withCheckedContinuation`）；失败且 `downloadRetry` 开启 → 上层弹重试（P1 先直接返回 nil 透传，重试对话框进任务 15 设置项说明，不做 UI）。

测试（`ResourceCacheTests`，用临时目录 + 本地假上游 NWListener 或 URLProtocol mock）：
```swift
func testCacheHitFresh()        // 预置缓存文件+版本表 → 返回缓存 body，未发网络请求
func testRevalidate304()        // 假上游返回 304 → 返回旧 body
func testRevalidate200()        // 假上游返回 200 新 body → 落盘且版本表更新
func testAssetReplacementFont() // 字体 URL → 返回内置 woff2（魔数 wOF2 校验）
func testNonGameHostPassthrough() // host=example.com → 返回 nil
```

- [ ] **步骤 2：实现 AssetReplacer.swift**

```swift
public struct AssetReplacer {
    let bundle: Bundle
    public init(bundle: Bundle = .main) { self.bundle = bundle }
    static let fontNames = ["A-OTF-UDShinGoPro-Medium", "A-OTF-UDShinGoPro-Bold", "A-OTF-UDShinGoPro-Heavy", "A-OTF-UDShinGoPro-Regular"]
    public func replacement(forPath path: String) -> (Data, String)? {
        // 字体：path 含 .woff2 → 按文件名匹配内置字体，mime application/font-woff2
        // /kcs/html/maintenance.html → 内置 maintenance.html
        // maintenance.png / tweenjs / rollover.js / kcs_cda.js / ooi.css 同法
        // 移植自 ResourceProcess.getFontFile/getMaintenanceFiles/getTweenJs/...
        return nil
    }
}
```

- [ ] **步骤 3：代理集成**

在 App 侧（RootView 或后续 AppState）：
```swift
let cache = ResourceCache(cacheDir: cachesURL, versionStore: vs, settings: settings)
proxy.onGameResourceRequest = { head in cache.response(for: head) }
```
`ResourceCache.response(for:)` 内部完成上述 6 步；回源经代理自身转发逻辑（返回 nil）或直接 URLSession 下载后返回完整响应（推荐后者，便于缓存）。

- [ ] **步骤 4：复制 assets 文件**（`mkdir Game/BundleAssets && cp` 上述文件），xcodebuild 验证打包无警告。

- [ ] **步骤 5：swift test + xcodebuild 验证**

- [ ] **步骤 6：Commit** — `git commit -m "feat(cache): 资源缓存/304 重校验/assets 替换/gadget 绕行"`

---

### 任务 9：ScriptPatcher（main.js 补丁）

**文件：**
- 创建：`Packages/GameCore/Sources/GameCore/ScriptPatcher.swift`
- 测试：`ScriptPatcherTests.swift`
- 参考：`ResourceProcess.patchMainScript`（静音/触摸/CAPTURE_LISTEN/MUTE_LISTEN 追加）、`touch_event_patch.js`

- [ ] **步骤 1：编写失败测试**

用 GotoBrowser 补丁的输入输出特征构造样本：
```swift
func testMutePatchApplied() {
    let sample = "...(含 patchMainScript 静音补丁锚点字符串的 main.js 片段，从 ResourceProcess.java 拷贝锚点)..."
    let out = ScriptPatcher().patchMainScript(sample, options: .init(muteOnStart: true, cursorMode: .touch))
    XCTAssertTrue(out.contains("global_mute"))
}
func testPatchMismatchTolerated() {
    let out = ScriptPatcher().patchMainScript("var x=1;", options: .init())
    XCTAssertEqual(out, "var x=1;".appendingTouchAndBridgeIfAnchorsMissing ? out : out) // 锚点缺失时原样返回（除追加段）
}
func testListenersAppended() {
    let out = ScriptPatcher().patchMainScript("var x=1;", options: .init())
    XCTAssertTrue(out.contains("webkit.messageHandlers.gotoBrowser"))  // CAPTURE/axios 拦截改为 iOS 桥
}
```

- [ ] **步骤 2：实现 ScriptPatcher.swift**

移植 `patchMainScript` 中 P1 范围的补丁，保持「锚点匹配不到就跳过该补丁」容错：
1. 静音补丁（音量初始值 + Howler 钩子）——逐字移植正则与替换串
2. 触摸事件补丁（pointer 事件表替换 + 追加 `touch_event_patch.js` 内容，cursorMode==.touch 时）
3. 追加 `MUTE_LISTEN`（桥调用改为 iOS messageHandlers 形式）
4. 追加 `CAPTURE_LISTEN`（同上改造）
5. 追加 axios/XHR 拦截脚本（移植 `KcsInterface.AXIOS_INTERCEPT_SCRIPT`：拦截 `svdata=` 响应，`JSON.stringify` 后 postMessage `{type:"kcsapi", endpoint, request, response}`；限制 host `*.kancolle-server.com`/`ooi.moe`；P1 只转发不存储）
6. 追加 ADJUST_SCRIPT（游戏画面缩放适配：隐藏 DMM 页面中非游戏的侧边栏/广告等元素——`.gamesResetStyle>:not(main){display:none}`，并把 1200px 游戏画面 `transform: scale` 铺满屏幕宽度。用户明确要求"登录后游戏控件部分全屏、网页其他部分不显示"，此补丁是实现手段；OOI 连接器页面结构不同，需配合任务 8 复制的 `game_custom.css`/`ooi.css` 资产替换，Spike/验收时逐连接器确认效果）

`patchMainScript` 在 `ResourceCache` 检测到 main.js 响应时调用（按 URL path 判断：`/kcs2/js/main.js`）。

- [ ] **步骤 3：运行验证通过 + xcodebuild**

- [ ] **步骤 4：Commit** — `git commit -m "feat(patch): main.js 补丁（静音/触摸/截图监听/kcsapi 拦截/画面适配）"`

---

### 任务 10：入口页 + Keychain + 登录自动化

**文件：**
- 创建：`Game/Entrance/EntranceView.swift`
- 创建：`Game/Entrance/KeychainStore.swift`
- 创建：`Game/Entrance/LoginAutomation.swift`
- 修改：`Game/RootView.swift`（入口页 → 游戏页流程）

- [ ] **步骤 1：KeychainStore.swift**

```swift
import Foundation
import Security

struct KeychainStore {
    private let service = "KanColle.Game.dmm"
    func save(id: String, password: String) {
        save(key: "id", value: id); save(key: "pass", value: password)
    }
    func load() -> (id: String, password: String)? {
        guard let id = read("id"), let pass = read("pass") else { return nil }
        return (id, pass)
    }
    func clear() { delete("id"); delete("pass") }
    private func save(key: String, value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var item = q; item[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
    private func read(_ key: String) -> String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
    }
}
```

- [ ] **步骤 2：EntranceView.swift**

UI：连接器 Picker（DMM direct / kancolle.moe / ooi.moe）、账号/密码输入（SecureField，「保存到钥匙串」开关，已有凭证时显示「已保存」）、静音启动开关、「开始游戏」按钮、右上角设置齿轮。开始游戏 → 存 Keychain → `onStart(connector)`。

- [ ] **步骤 3：LoginAutomation.swift**

挂载到 WebViewCoordinator 的 `didFinish`：
```swift
final class LoginAutomation {
    let settings: SettingsStore
    let keychain: KeychainStore
    func handlePageFinished(_ webView: WKWebView) {
        guard let url = webView.url?.absoluteString else { return }
        // 1. 地区限制页 → 注入 DMM_COOKIE（ckcy=1，用 WKHTTPCookieStore 写 cookie）→ load(connector.url)
        //    移植 BrowserActivity/WebViewManager 中 foreign 检测分支
        // 2. DMM 登录页 → 从 Keychain 读凭证 → evaluateJavaScript(AUTOCOMPLETE_DMM 填入 id/pass)
        // 3. OOI/kancolle.moe 登录页 → AUTOCOMPLETE_OOI
        // 4. Google 登录页（accounts.google.com）→ 切 userAgentMobile（WebViewManager.setWebViewRendererSetting 对应分支）
    }
}
```
cookie 写入用 `WKHTTPCookieStore.setCookie`（ckcy=1, domain .dmm.com, 1 年有效期）而非 JS `document.cookie`（HttpOnly 兼容更好）。

- [ ] **步骤 4：RootView 流程接线**

`@State phase: .entrance | .game`；入口页「开始游戏」→ `.game` 显示 GameView（任务 11 先做容器，本轮先直接用 BrowserView）。

- [ ] **步骤 5：xcodebuild 验证 + 模拟器手测**（打开 DMM 登录页，确认自动填充执行）

- [ ] **步骤 6：Commit** — `git commit -m "feat(entrance): 入口页/Keychain 凭证/登录自动填充/地区绕行"`

---

### 任务 11：GameView + 悬浮球框架

**文件：**
- 创建：`Game/Game/GameView.swift`
- 创建：`Game/Game/FloatingBallView.swift`
- 创建：`Game/Game/FloatingMenuView.swift`

- [ ] **步骤 1：FloatingBallView.swift**

```swift
import SwiftUI

struct FloatingBallView: View {
    @GestureState private var dragOffset: CGSize = .zero
    @State private var position: CGPoint
    let onTap: () -> Void

    init(initial: CGPoint = CGPoint(x: 340, y: 120), onTap: @escaping () -> Void) {
        _position = State(initialValue: initial)
        self.onTap = onTap
    }

    var body: some View {
        Image(systemName: "circle.grid.2x2.fill")
            .font(.system(size: 22))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.45), in: Circle())
            .position(x: position.x + dragOffset.width, y: position.y + dragOffset.height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragOffset) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        var p = CGPoint(x: position.x + v.translation.width, y: position.y + v.translation.height)
                        // 贴边吸附：x 吸附到较近屏幕边（读取 UIScreen 边界由父级传入，此处用 GeometryReader 包裹处理）
                        position = p
                    }
            )
            .onTapGesture { onTap() }  // 与拖动区分：拖距 < 10pt 视为点按（SwiftUI 默认手势竞争可处理）
    }
}
```
说明：贴边吸附需要父容器尺寸——用 GeometryReader 包一层，onEnded 时把 x 收到 `24` 或 `width-24`；y 钳制在安全区内。

- [ ] **步骤 2：FloatingMenuView.swift**

半透明全屏遮罩 + 球旁弹出的纵向按钮列：截图 / 静音切换 / 刷新 / 设置 / 退出到入口页。点击遮罩关闭。P1 的舰队/战斗/任务按钮不显示（P2/P3 再加）。

- [ ] **步骤 3：GameView.swift**

ZStack：`BrowserView`（全屏）→ `SubtitleBarView`（顶部，任务 13）→ `FloatingBallView` + 条件 `FloatingMenuView`。持有 `@State showMenu`、静音状态（菜单静音切换 → `webView.evaluateJavaScript(MUTE_SEND_*)`）。

- [ ] **步骤 3.5：进入游戏后锁定横屏（用户明确要求）**

GameView `onAppear` 时锁定横屏，退出到入口页时恢复全方向：
```swift
// Game/Browser/OrientationLock.swift
import UIKit

enum OrientationLock {
    static var current: UIInterfaceOrientationMask = .allButUpsideDown
    static func lock(_ mask: UIInterfaceOrientationMask, rotateTo orientation: UIInterfaceOrientation? = nil) {
        current = mask
        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            scenes.forEach { scene in
                let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
                scene.requestGeometryUpdate(prefs) { _ in }
            }
        }
        if let orientation {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        }
    }
}
```
并在 `GameApp.swift` 加 AppDelegate 桥接使锁定生效：
```swift
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.current
    }
}
// GameApp 内：@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
```
GameView `onAppear` → `OrientationLock.lock(.landscape)`；`onDisappear` → `OrientationLock.lock(.allButUpsideDown)`。Info.plist 已声明三方向，无需改动。

- [ ] **步骤 4：xcodebuild 验证 + 模拟器手测悬浮球拖动/菜单/横屏锁定**

- [ ] **步骤 5：Commit** — `git commit -m "feat(game): 游戏画面容器与悬浮球/菜单覆盖层"`

---

### 任务 12：截图

**文件：**
- 创建：`Game/Capture/ScreenshotSaver.swift`
- 修改：`Game/Game/GameView.swift`（菜单「截图」按钮接线）

- [ ] **步骤 1：ScreenshotSaver.swift**

```swift
import Photos
import UIKit

enum ScreenshotSaver {
    static func save(dataURL: String) async -> Bool {
        guard let range = dataURL.range(of: "base64,"),
              let image = UIImage(data: Data(base64Encoded: String(dataURL[range.upperBound...])) ?? Data()) else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { cont.resume(returning: false); return }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: image.pngData() ?? Data(), options: nil)
                } completionHandler: { ok, _ in cont.resume(returning: ok) }
            }
        }
    }
}
```

- [ ] **步骤 2：接线**

菜单「截图」→ `webView.evaluateJavaScript(CAPTURE_SEND_DMM/OOI)`（按连接器选）→ JSBridge `.capture(dataURL)` 事件 → ScreenshotSaver → toast（成功「已保存到相册」/失败提示）。toast 用 SwiftUI 简单覆盖层实现。

- [ ] **步骤 3：xcodebuild 验证 + 手测保存**

- [ ] **步骤 4：Commit** — `git commit -m "feat(capture): 游戏内截图保存相册"`

---

### 任务 13：字幕系统

**文件：**
- 创建：`Packages/GameCore/Sources/GameCore/SubtitleStore.swift`
- 创建：`Packages/GameCore/Sources/GameCore/VoiceLineMatcher.swift`
- 创建：`Game/Subtitle/SubtitleBarView.swift`
- 测试：`VoiceLineMatcherTests.swift`
- 参考：`Subtitle/Kc3SubtitleProvider.java`（563 行，语音编号算法全量移植）、`Subtitle/KcwikiSubtitleProvider.java`、`Subtitle/SubtitleProviderUtils.java`、`assets/quotes_label.json`

- [ ] **步骤 1：SubtitleStore.swift**

- KC3 源：`https://raw.githubusercontent.com/KC3Kai/kc3-translations/master/data/{locale}/quotes.json` + `src/data/quotes_size.json`（locale：en/jp/kr/scn/tcn——核对 KC3 目录名，以 `Kc3SubtitleCheck/Repo` 为准）
- kcwiki 中文源：移植 `KcwikiSubtitleApi` 的请求 URL
- 下载到 `Caches/subtitle/quotes_<locale>.json`，解析为 `[String: String]`（语音编号 → 文本），带版本检查（quotes_size.json 或 ETag）

- [ ] **步骤 2：VoiceLineMatcher 移植（TDD）**

**这是 P1 最精细的移植**：`Kc3SubtitleProvider.computeVoiceDiff` 的语音文件名 → 语音编号映射（含改造链回退、季节语音文件大小匹配）。
- 执行者先通读 `Kc3SubtitleProvider.java`，**手工推演 3 组输入输出**（选 1 个普通舰娘语音、1 个改造舰娘、1 个季节语音），把推演结果写成测试期望值
- 然后逐行移植为 Swift，直到测试通过
- API：`func match(shipID: Int, voiceFileName: String, fileSize: Int64) -> String?`（返回字幕文本 key 或直接返回文本，按原实现结构）

- [ ] **步骤 3：语音 URL 捕获 + SubtitleBarView**

- 在 `ResourceCache` 或代理日志中识别 `/kcs2/resources/voice/` 请求（含 shipID 与文件名、大小），经回调抛给 App 侧
- `SubtitleBarView`：游戏画面顶部半透明条，显示匹配字幕 3 秒淡出；`subtitleEnabled`/`fontSize` 受设置控制

- [ ] **步骤 4：swift test + xcodebuild 验证**

- [ ] **步骤 5：Commit** — `git commit -m "feat(subtitle): 语音字幕（KC3/kcwiki 数据源 + 语音编号匹配移植）"`

---

### 任务 14：MemoryMonitor + 白屏恢复完善 + 诊断

**文件：**
- 创建：`Game/Health/MemoryMonitor.swift`
- 创建：`Game/Health/DiagnosticsStore.swift`（替换任务 5 的最小版）
- 修改：`Game/Game/GameView.swift`（告警弹窗）

- [ ] **步骤 1：DiagnosticsStore.swift**

`@Observable final class DiagnosticsStore`：进程终止次数、最近终止时间、导航错误日志（环形 50 条）、内存采样历史（最近 60 个点：App 驻留 MB + JS 堆 MB）。单例 `shared`。

- [ ] **步骤 2：MemoryMonitor.swift**

```swift
import Foundation

@Observable final class MemoryMonitor {
    enum Level { case normal, warning }
    private(set) var residentMB: Double = 0
    private(set) var jsHeapMB: Double = 0
    private(set) var thresholdMB: Double
    var onThresholdExceeded: (() -> Void)?
    private var timer: Timer?
    private var warned = false

    init(thresholdMB: Double? = nil) {
        // 默认设备物理内存 40%（规格 §5.3）
        self.thresholdMB = thresholdMB ?? Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576.0 * 0.4
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() { timer?.invalidate() }
    func updateJSHeap(_ mb: Double) { jsHeapMB = mb; check() }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { residentMB = Double(info.phys_footprint) / 1_048_576.0 }
        check()
    }

    private func check() {
        let over = residentMB > thresholdMB || jsHeapMB > 400  // 规格：JS 堆 400MB
        if over && !warned { warned = true; onThresholdExceeded?() }
        if !over { warned = false }
    }
}
```

- [ ] **步骤 3：告警弹窗 + 恢复接线**

GameView 中：`memoryMonitor.onThresholdExceeded` → Alert「内存占用过高」三按钮（清理缓存 = 清内存层缓存 + `URLCache.shared.removeAllCachedResponses()`；重新加载 = webView.reload()；忽略）。JSBridge `.memoryReport` → `memoryMonitor.updateJSHeap`。白屏恢复已在任务 5 挂载，本任务补 toast 提示「页面已自动恢复」。

- [ ] **步骤 4：xcodebuild 验证**

- [ ] **步骤 5：Commit** — `git commit -m "feat(health): 内存监测/阈值告警/诊断记录"`

---

### 任务 15：设置页

**文件：**
- 创建：`Game/Settings/SettingsView.swift`

- [ ] **步骤 1：SettingsView.swift**

分组 Form（全部读写 SettingsStore）：
- 基本：连接器、静音启动、Canvas 渲染器（legacyRenderer）、触摸/鼠标模式、屏幕常亮、字幕开关/语言/字号
- 缓存：缓存开关、清理缓存按钮（删 `browser_cache/` + VersionStore.removeAll() + 补丁缓存）、gadget 绕行开关/端点
- 下载：失败重试开关
- 健康：内存告警开关/阈值、诊断信息（白屏次数/最近错误，只读）
- 账号：清除保存的 DMM 凭证
- 关于：版本号

- [ ] **步骤 2：入口页与悬浮球菜单接入设置页**（sheet 呈现）

- [ ] **步骤 3：xcodebuild 验证 + 手测每个开关持久化**

- [ ] **步骤 4：Commit** — `git commit -m "feat(settings): 完整设置页"`

---

### 任务 16：P1 验收

- [ ] **步骤 1：全量构建与测试**

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore && swift test
xcodebuild -project /Users/haozhe/WorkTest/Game/Game.xcodeproj -scheme Game -destination 'generic/platform=iOS Simulator' build
```
预期：全部通过。

- [ ] **步骤 2：手动验收清单（真机，逐项打勾写入 P1 验收记录）**

1. 入口页选择 DMM，输入账号密码，开始游戏 → 自动填充登录成功进入母港
2. 地区限制页面被自动绕过（如网络环境触发）
3. 游戏画面占满横屏、比例正确（ADJUST_SCRIPT 生效）
4. 断网重进：已缓存的立绘/音频秒开（缓存生效）
5. 悬浮球可拖动贴边，菜单弹出，截图成功存相册
6. 静音开关生效；字幕随语音显示（有字幕数据时）
7. 连续游玩 30 分钟：无白屏，或白屏后自动恢复且 toast 提示
8. 内存告警可被触发（可用 Debug 菜单临时调低阈值验证）
9. OOI 连接器登录可用
10. 设置项全部持久化（重启 App 保持）

- [ ] **步骤 3：验收记录 commit**

`docs/superpowers/p1-acceptance.md` 记录结果 → `git commit -m "docs: P1 验收记录"`

---

## 自检记录（计划作者填写）

- **规格覆盖度**：P1 范围内——连接器/登录/地区绕行（任务 2/10）、资源缓存（7/8）、gadget 绕行（8）、静音（9/11）、截图（9/12）、触摸补丁（9）、字幕（13）、白屏恢复+内存监测（5/14）、悬浮球框架（11）、设置页（15）、画面适配 ADJUST_SCRIPT（9）。DMM 密码 Keychain（10）。✅
- **已知取舍**：keep-alive、多标签、KCCP/FPS/暴击/Kantai3D Mod 不在 P1（规格 P4）；poi 上报 P4；本地推送 P2。
- **最大风险**：任务 6 Spike 的 http→https 自动升级。若触发，后续任务 8/9 的接入点不变（仍在代理/缓存层），仅资源 URL 改写策略变化。
