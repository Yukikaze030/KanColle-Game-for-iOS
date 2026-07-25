# Kcanotify + GotoBrowser 合并 iOS App 设计规格

- 日期：2026-07-25
- 状态：待用户审查
- 工程位置：`/Users/haozhe/WorkTest/Game`（现有 SwiftUI 模板工程）
- 参考项目：`/Users/haozhe/GitHub/kcanotify-master`、`/Users/haozhe/GitHub/GotoBrowser`（均为 GPLv3，作者 antest1）

## 1. 目标

将 Android 上的 GotoBrowser（舰 C HTML5 浏览器）与 Kcanotify（舰 C 数据工具）合并为一个 iOS App，支持两者的全部功能（平台专有、无意义的除外，见 §8）。游戏在本 App 内置浏览器中游玩，工具数据通过应用内 JS 拦截获得，无需 VPN。

## 2. 已确认的约束与决策

| 项目 | 决策 |
|---|---|
| 分发方式 | 个人开发/侧载，不受 App Store 审核限制 |
| 数据捕获 | 仅应用内捕获：内置浏览器 JS 层拦截 kcsapi 响应 |
| 交付节奏 | 分阶段交付（P1→P4，见 §7） |
| 目标设备 | iPhone 优先，兼顾 iPad；横屏为主 |
| 最低系统 | iOS 17（依赖 `WKWebsiteDataStore.proxyConfigurations`） |
| 界面语言 | 多语言框架（String Catalog），默认简体中文；字幕语言数据沿用 KC3/kcwiki 多语言源 |
| 工具入口 | 悬浮球（游戏中屏幕上只有游戏画面 + 悬浮球） |
| 连接器 | DMM 直连 / ooi.moe / kancolle.moe 全部保留 |
| 凭证存储 | DMM 账号密码存 iOS Keychain（Android 版明文 SharedPreferences 不沿用） |

## 3. UI 流程

```
启动 → 入口页（连接器选择 + 账号密码输入/保存 + 设置入口）
     → 登录（凭证从 Keychain 读取，注入 JS 自动填充到登录页并提交）
     → 游戏画面 + 悬浮球（可拖动，贴边停靠）
        └─ 点击悬浮球 → 放射/列表菜单 → 舰队 / 战斗 / 任务 / 工具 / 设置（覆盖层打开）
```

iPad 额外能力：工具面板可与游戏画面并排（Split 布局），但悬浮球模式同样可用。此为大屏增强，不影响 iPhone 优先的实现顺序。

## 4. 总体架构

四层，每层单一职责，通过定义良好的接口通信：

```
┌─ UI 层（SwiftUI）────────────────────────────────────────────┐
│ 入口/连接器选择 · 游戏画面+悬浮球 · 工具覆盖层页面 · 设置      │
└──────────────▲──────────────────────────────┬───────────────┘
        @Observable 状态驱动            用户操作
┌──────────────┴──────────────────────────────▼───────────────┐
│ BrowserEngine                                               │
│  WebViewManager（WKWebView 配置/UA/Cookie/JS 注入/白屏恢复）  │
│  LocalProxy（SwiftNIO 本地代理，域名级路由）                  │
│  ResourceInterceptor（WKURLSchemeHandler，内容级缓存/补丁）   │
│  ScriptPatcher（main.js 补丁：静音/截图/触摸/FPS/暴击/翻译）  │
└──────────────┬──────────────────────────────────────────────┘
   kcsapi 响应（axios 拦截 → WKScriptMessageHandler）
┌──────────────▼──────────────────────────────────────────────┐
│ DataPipeline                                                │
│  ApiParser（svdata 解析、端点路由、api_start2 母数据）        │
│  GameState（舰队/入渠/远征/士气，@Observable 单一事实来源）   │
│  BattleEngine（战斗推演）· QuestTracker（任务进度）           │
└──────────────┬──────────────────────────────────────────────┘
   状态变更事件
┌──────────────▼──────────────────────────────────────────────┐
│ 服务层                                                      │
│  NotificationService（本地推送）· DataStore（SQLite/UD/文件） │
│  AssetDownloader（静态数据/字幕/补丁更新）· WidgetKit 小组件  │
└─────────────────────────────────────────────────────────────┘
```

### Android 组件移植映射

| Android | iOS |
|---|---|
| `WebViewClient.shouldInterceptRequest` | LocalProxy（域名级）+ WKURLSchemeHandler（内容级） |
| `JavascriptInterface` / axios 拦截 | `WKScriptMessageHandler` → DataPipeline |
| `KcaVpnService`（VPN 抓包） | 不需要（应用内捕获） |
| 悬浮窗 Service ×14 | SwiftUI 覆盖层页面（悬浮球唤起） |
| AlarmManager + 前台服务 | `UNNotificationRequest` 本地推送（无需后台运行） |
| SQLite / SharedPreferences / 文件缓存 | SQLite / UserDefaults / 应用沙盒目录 |
| 桌面 AppWidget | WidgetKit 小组件 |

## 5. BrowserEngine 详细设计

### 5.1 混合拦截分工

| 层级 | 机制 | 职责 |
|---|---|---|
| 域名级 | LocalProxy（SwiftNIO，localhost，经 `proxyConfigurations` 挂载） | 广告/追踪域名阻断、gadget 绕行（URL 替换方式）、请求日志 |
| 内容级 | `WKURLSchemeHandler`（自定义 scheme `kc-cache://`） | 资源缓存命中返回本地文件、assets 替换（字体/维护页等）、返回打过补丁的 main.js |
| 页面级 | `WKUserScript` 注入 | 资源 URL 改写为 `kc-cache://`、axios 拦截 kcsapi、静音/截图/触摸补丁、字幕钩子 |

HTTPS 下本地代理看不到内容（只能看到 CONNECT 目标），因此内容级操作全部走 scheme 改写路径——与 GotoBrowser 的「URL 替换式 gadget 绕行」同构，代码逻辑可移植。`patchMainScript` 的补丁（静音、FPS 解锁、暴击显示、KCCP 翻译、触摸事件表替换）是纯字符串/正则处理，直接移植，在 scheme handler 返回 main.js 前依次应用，沿用原项目「匹配不到就放弃」的容错策略。

### 5.2 登录与地区绕行

- DMM：检测登录页加载完成 → 注入 JS 从 Keychain 读取凭证自动填充并提交；检测地区限制页 → `WKHTTPCookieStore` 写入 `ckcy=1` cookie → 跳回游戏页
- OOI / kancolle.moe：表单 POST 登录
- 三套 UA 保留：桌面 Chrome / iOS Safari（强制 Canvas 渲染器）/ 移动版（Google 登录时切换，Google 屏蔽 WebView UA）

### 5.3 白屏防护与内存监测

背景：WKWebView 的 WebContent 进程内存预算由系统控制且无法提高，超限即被杀导致白屏。策略为「降压力 + 优雅恢复 + 监测预警」：

- **降压力**：默认 Canvas 渲染器模式（UA 伪装，设置中可切回 WebGL）；资源本地缓存减少网络进程负担；`didReceiveMemoryWarning` 时释放内存缓存（磁盘缓存保留）；全 App 仅一个 WKWebView 实例
- **优雅恢复**：`webViewWebContentProcessDidTerminate` → 自动 reload 并 toast 提示；JS 监听 `webglcontextlost/restored`，能局部恢复则不整页刷新；终止次数计入诊断
- **内存监测（新增）**：定时采样 App 驻留内存（`task_vm_info`）+ 页面 JS 堆（`performance.memory`，注入脚本周期上报）；超过阈值弹窗警告——默认阈值：App 驻留内存 > 设备物理内存的 40%，或页面 JS 堆 > 400MB（两者均在设置页可调）；提供「清理缓存 / 重新加载 / 忽略」三个选项；采样历史写入设置页诊断信息

### 5.4 截图 / 字幕 / 音量

- 截图：注入 JS → canvas `toDataURL` → messageHandler 回传 → `PHPhotoLibrary` 存相册 + 通知
- 字幕：语音文件名 → 语音编号算法（移植 `Kc3SubtitleProvider`，含改造链回退、季节语音文件大小匹配）+ kcwiki 中文源；SwiftUI 字幕条叠加在游戏画面上，字号可调
- 静音：Howler 补丁（`add_bgm`/`global_mute` 钩子）+ 启动静音开关，纯 JS 层

## 6. DataPipeline 详细设计

```
页面 axios 拦截 → WKScriptMessageHandler（端点 + 请求体 + svdata JSON）
→ ApiParser：剥离 svdata=、JSON 解析、按端点路由
→ GameState 写入（@Observable）：
   · port / 舰队 / 装备端点 → FleetState（4 舰队、舰娘 HP/士气/装备、索敌/制空计算）
   · 入渠端点 → DockingState（4 渠完成时刻）
   · 远征端点 → ExpeditionState（完成时刻）
   · 战斗端点 → BattleEngine 逐阶段推演（昼战/夜战/航空战/雷击，大破/损管/退避判定）
   · 任务端点 → QuestTracker 进度累计
   · 掉落/建造/开发/资源 → DataStore SQLite 日志
→ 副作用：NotificationService 预约/更新本地推送；poi-statistics 上报（可选开关，默认关）
```

- `api_start2` 母数据与多语言翻译 JSON 随包内置，启动时检查更新（移植 assets 中约 40 个 JSON 及 `KcaDownloader` 下载逻辑，源服务器 luckyjervis.com / KC3 / kcwiki-api）
- 索敌/制空计算移植自 kcanotify 现有实现
- BattleEngine 移植 `KcaBattle`（2225 行）：不模拟战斗，解析战斗 API 响应逐阶段应用伤害推算结果。移植时按战斗阶段拆分为多个可独立测试的单元，不保留单个大类

## 7. 分阶段交付

| 阶段 | 内容 | 移植来源 |
|---|---|---|
| **P1 浏览器核心** | 连接器/登录/地区绕行、资源缓存、gadget 绕行、静音、截图、触摸补丁、字幕、白屏恢复 + 内存监测、悬浮球框架、设置页 | GotoBrowser 核心（ResourceProcess / WebViewManager / BrowserActivity / Subtitle 包） |
| **P2 基础工具** | DataPipeline、舰队视图（索敌/制空/士气/大破警告）、远征/入渠/士气/明石本地推送、WidgetKit 小组件 | KcaService / KcaApiData / KcaDeckInfo / KcaAlarmService |
| **P3 战斗与任务** | 战斗预测（BattleEngine + 战斗画面）、海域血条/陆航面板、任务视图（翻译 + 进度追踪） | KcaBattle / KcaBattleViewService / KcaQuestTracker（约 5600 行，最大工程） |
| **P4 其余工具** | 明石改修工厂、舰娘/装备列表、经验计算器、远征一览、掉落/资源日志（图表）、建造/开发结果、数据备份恢复、妖精皮肤下载、poi 上报、游戏 Mod（FPS 解锁、暴击显示、KCCP 翻译补丁、Kantai3D） | kcanotify 其余模块、GotoBrowser Mod（Helpers/ 包） |

每阶段交付可用产品，后续阶段不破坏前阶段功能。实现计划按阶段分别制定：本规格批准后首先为 P1 编写实现计划，P2–P4 的计划在前一阶段完成后编写。

## 8. 不移植项（明确排除）

- VPN 抓包（KcaVpnService / netguard / mitm）：应用内捕获取代
- Kcanotify 广播 / ContentProvider 联动：合并后进程内直连
- Android 画中画、三星多窗口、桌面 AppWidget（WidgetKit 替代）
- 代理式 gadget 绕行（ProxyController）：仅保留 URL 替换式
- Google Play / Firebase 相关（如需崩溃上报再评估，初版不含）

## 9. 数据层

- **SQLite**（使用 GRDB.swift）：用户舰娘/装备快照、任务进度、掉落日志、资源日志、错误日志、资源版本表（移植 `KcaDBHelper` 与 `VersionDatabase` 表结构）
- **UserDefaults**：全部设置项（移植 `KcaConstants.PREF_*` 与 GotoBrowser `Constants.PREF_*` 键设计）
- **Keychain**：DMM 账号密码
- **文件缓存**（沙盒 Caches 目录）：`browser_cache/` 游戏资源、`subtitle/` 字幕数据、`patch/` KCCP 补丁、图片资源；缓存过期策略移植（Last-Modified 304 + max-age）
- **assets 内置**：api_start2 缓存、翻译 JSON、明石数据、经验表、海图节点、字体 woff2、注入用 JS/CSS（touch_event_patch.js、game_custom.css 等）

## 10. 错误处理

- 资源下载失败：沿用 GotoBrowser 重试对话框策略（可设置关闭）
- main.js 补丁失配：跳过该补丁并记录（游戏更新后容错，不因补丁失效导致游戏不可用）
- kcsapi 解析失败：记录原始报文到错误日志（对应 ErrorlogActivity 功能），不中断数据管道
- WebContent 进程终止：自动 reload + toast + 计数（§5.3）
- 网络/SSL 错误：对应原项目的错误对话框，给出错误码说明
- 本地通知上限（64 条）：NotificationService 只保留每个计时器最近一条，过期即清理

## 11. 测试策略

- **单元测试**：ApiParser（用真实抓包样本做 fixture）、BattleEngine（按战斗阶段用例）、索敌/制空计算、字幕语音编号算法、缓存过期逻辑
- **集成测试**：scheme handler 缓存命中/未命中路径、通知预约逻辑
- **手动验证清单**（每阶段）：P1 实机登录 DMM/OOI 并游玩 30 分钟无白屏；P2 远征通知准时到达；P3 战斗预测与实际结果一致
- 测试样本：从 Android 版 kcanotify 的错误日志/抓包功能导出真实 API 响应作为 fixture

## 12. 主要风险

| 风险 | 缓解 |
|---|---|
| iOS 17 以下设备不可用 | 个人侧载场景可接受；如需支持旧系统再评估降级路径（纯 scheme 方案） |
| 游戏更新导致 main.js 补丁失配 | 容错跳过 + 补丁可在线更新（AssetDownloader） |
| WKWebView 内存被杀 | §5.3 三层策略 |
| BattleEngine 移植量大易错 | 拆分为小单元 + 真实抓包 fixture 驱动测试 |
| kcwiki/KC3 字幕源变动 | 字幕下载失败时静默降级为无字幕，不影响游戏 |
