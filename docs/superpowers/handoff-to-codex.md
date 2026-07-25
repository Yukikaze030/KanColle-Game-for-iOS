# P1 进度交接文档（交给 CodeX）

**日期：** 2026-07-25
**分支：** `p1-browser-core`（不要建新分支）
**工程根：** `/Users/haozhe/WorkTest/Game`
**接收方：** CodeX CLI

## 1. 一句话目标

将 Android 上的舰 C 浏览器（GotoBrowser）与舰 C 数据工具（kcanotify）合并移植到一个 iOS App，本分支（P1）交付**可实际游玩的浏览器核心**：连接器/登录、资源缓存、静音/截图、字幕、白屏恢复 + 内存监测、悬浮球框架、设置页。

## 2. 当前进度（按任务 1–16 编号）

| # | 任务 | 状态 |
|---|---|---|
| 1 | 工程配置 + GameCore 包骨架 | ✅ 已 commit `2e65f5a` |
| 2 | BrowserConstants + SettingsStore | ✅ 已 commit `7d0de9e`（双审查通过） |
| 3 | ProxyHTTPParser + BlockRules | ✅ 已 commit `0568a97`（双审查通过） |
| 4 | LocalProxyServer | ✅ 已 commit `ffc5989`（含 POST body 修复 + crash 防护等，双审查通过） |
| 5 | WebView 基础（BrowserView/Coordinator/JSBridge/RootView） | ✅ 已 commit `c5bd55a`（双审查通过 + 脚本时序修复） |
| 6 | 技术验证 Spike | ✅ 已完成；冒烟证明：代理接管流量 ✅、iframe JS 注入 + kcsapi 钩子 ✅、**游戏资源全走 HTTPS（明文 HTTP 假设不成立）** ❌。结论：采用 **CA 证书 + MITM** 方案 |
| **6A** | **MitmCA（根 CA 生成 + 站点证书签发 + Keychain 持久化）** | ⬜ **未开始，CodeX 接手第一个任务** |
| **6B** | **证书安装引导 + 代理 MITM 解密通道集成** | ⬜ 未开始 |
| 7 | VersionStore + CachePolicy | ⬜ 未开始 |
| 8 | ResourceCache + AssetReplacer + 代理集成 + gadget 绕行 | ⬜ 未开始 |
| 9 | ScriptPatcher（main.js 补丁：静音/触摸/截图/kcsapi 拦截/画面适配） | ⬜ 未开始 |
| 10 | 入口页 + Keychain + 登录自动化 + 地区绕行 | ⬜ 未开始 |
| 11 | GameView + 悬浮球 + 菜单 + **横屏锁定** | ⬜ 未开始 |
| 12 | 截图（dataURL → 相册） | ⬜ 未开始 |
| 13 | 字幕系统（KC3/kcwiki 数据 + VoiceLineMatcher 移植） | ⬜ 未开始 |
| 14 | 内存监测 + 白屏恢复完善 + 诊断 | ⬜ 未开始（**仅原生 phys_footprint，JS 堆指标弃用**） |
| 15 | 设置页 | ⬜ 未开始 |
| 16 | P1 验收 | ⬜ 未开始 |

## 3. 关键文档（请先通读）

| 路径 | 用途 |
|---|---|
| `docs/superpowers/specs/2026-07-25-kcanotify-gotobrowser-ios-design.md` | 设计规格（已批准）。注意 §5.1 是 Spike 后修订版（MITM 架构） |
| `docs/superpowers/plans/2026-07-25-p1-browser-core.md` | 实现计划（1480 行）。**任务 6A/6B 已在计划中**（位于任务 6 与任务 7 之间） |
| `docs/superpowers/spike-results.md` | Spike 完整结论与依据 |
| `/Users/haozhe/GitHub/GotoBrowser/app/src/main/java/com/antest1/gotobrowser/` | Android 参考源码（移植依据） |
| `/Users/haozhe/GitHub/kcanotify-master/` | Android 参考源码 |

## 4. 用户硬约束（不可违反）

1. **全部使用 Apple 原生 API**：禁止 SwiftNIO、GRDB.swift、SQLite.swift、Alamofire、Starscream 等任何第三方依赖。
2. **控件与 API 实现优先使用 Swift 原生（Apple 第一方）API**。API 签名以 `https://developer.apple.com/documentation` 为准；遇到不确定可用 `WebFetch` 查 Swift interface / 文档。
3. **每个可编译单元完成后必须用 xcodebuild 验证**；逻辑包测试用 `swift test`。**本机 xcode-select 指向 Command Line Tools，所有命令必须加前缀 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`**。
4. **不在 main 分支上直接实现**——已在 p1-browser-core 分支上工作。
5. **个人侧载使用**：不上 App Store；功能不受审核限制（可以保留地区绕行、CA 安装引导、keystore 存储凭证等）。

## 5. 环境与工具链

- macOS、Darwin 25.5.0，Xcode 已装（`/Applications/Xcode.app`）。
- Xcode 工程：`Game.xcodeproj`（objectVersion 77，使用 `PBXFileSystemSynchronizedRootGroup`——向 `Game/` 目录添加文件即自动入编译，**无需修改 pbxproj**）。
- 本地 SPM 包：`Packages/GameCore`（用 swift test 直接测）。**已链入 App target**。
- Bundle ID：`KanColle.Game`；部署目标 iOS 17.0。
- **构建命令**（每个任务结束必跑）：
  ```bash
  cd /Users/haozhe/WorkTest/Game/Packages/GameCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```
  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project /Users/haozhe/WorkTest/Game/Game.xcodeproj -scheme Game -destination 'generic/platform=iOS Simulator' build
  ```
- 模拟器冒烟（任务 6/6B 等需要真实流量验证时）：
  ```bash
  xcrun simctl list devices available
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project /Users/haozhe/WorkTest/Game/Game.xcodeproj -scheme Game -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  xcrun simctl boot <UDID> 2>/dev/null
  xcrun simctl install booted <APP路径>
  xcrun simctl launch booted KanColle.Game
  xcrun simctl io booted screenshot /tmp/<name>.png
  ```
  获取 APP 路径：`xcodebuild -showBuildSettings | grep ' BUILT_PRODUCTS_DIR\| FULL_PRODUCT_NAME'`。

## 6. 架构变更重点（Spike 后续接手必读）

原计划假设 `kancolle-server.com` 是明文 HTTP（Android `usesCleartextTraffic=true`）。**Spike 证实 iOS 上游戏资源全走 HTTPS**——所以资源缓存和 main.js 补丁不能简单靠代理层转发实现，需 MITM 解密：

- **MITM 路径**：App 启动生成设备本地根 CA（私钥存 Keychain）→ 用户在系统设置「安装描述文件并启用完全信任」→ 代理对 `*.kancolle-server.com` 的 CONNECT 隧道现场签发站点证书、终止 TLS → 游戏流量解密为明文 → 缓存/补丁生效。
- **MITM 面最小化**：仅游戏域名解密；DMM/osapi 等其他域名一律盲隧道。
- **任务 6B 的关键技术点**：Network 框架不支持在既有 NWConnection 上叠加服务端 TLS，所以 MITM 终止改用 **BSD socket + SecureTransport（iOS SDK 仍提供 `SecureTransport.h`，已 deprecated 但可用，属 Apple 原生）** 的内存 BIO 模式：NWConnection 当纯字节泵，数据喂给 `SSLSetIOFuncs` 自定义回调的 SSLRead/SSLWrite。**详见计划文档任务 6B 步骤 1**。

## 7. 已搭建的临时 Spike 代码（任务 6 用，需要清理）

位于 `Game/RootView.swift`：连接器选择页、代理日志面板、iframe kcsapi XHR 钩子、main.js 内容改写探针（用 `Data(contentsOf:)` 同步拉上游改写）、`-SpikeConnector` 启动参数钩子。均带 `TODO(任务6后清理)` 标记，任务 6B 完成后会清理重构成正式 RootView。

## 8. 工作流建议

- 每个任务用 superpowers 模板（TDD → 实现 → xcodebuild 验证 → 自审 → 汇报），双审查通过后再进入下一个。
- 大任务（如 6B）建议拆成子任务执行，提交多次。
- 遇到阻塞或架构抉择，用 `WebFetch` 查 Apple 文档；不确定 API 时优先看 SDK 的 `.swiftinterface`（`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/.../*.swiftinterface`）。

## 9. 当前分支头部

```
f7928ba feat(spike): iframe kcsapi XHR 钩子与 main.js 内容改写探针（含 -SpikeConnector 冒烟启动参数）
```

下一步从任务 6A 开始。建议先通读 plan 文档中任务 6A 的完整定义（含 Security 框架自编码 X.509 v3 证书的关键说明），再开工。