# P1 技术验证 Spike 结果

日期：2026-07-26 · 分支 p1-browser-core · 已完成任务 6B 复验

## 验证结果

| # | 验证项 | 结果 | 证据 |
|---|---|---|---|
| 1 | 代理接管 WebView 全部流量 | ✅ 通过 | 日志面板出现全部 dmm.com 等域名的 `[200] CONNECT host:443` 记录 |
| 2 | DMM 登录页可达 | ✅ 通过 | 冒烟截图：DMM GAMES 登录页完整渲染 |
| 3 | 游戏资源明文请求可见 | ✅ **MITM 后通过** | 安装并完全信任本地根 CA 后，日志出现 `[KC] GET/POST ...kancolle-server.com` |
| 4 | http→https 自动升级 | **已确认发生**（或 DMM 已全站 HTTPS） | 同 #3，isInspectableHost（port 80）路径从未触发 |
| 5 | HTTPS 内容可进入代理资源处理链 | ✅ 通过 | CONNECT → 本地 TLS 终止 → 解密 HTTP 请求链路已在模拟器实测；正式 main.js 补丁由任务 9 接入 |
| 6 | iframe JS 注入 + kcsapi 钩子 | ✅ 通过 | 日志出现 `[API] /kcsapi/api_start2/get_option_setting`——WKUserScript（forMainFrameOnly: false）成功装进游戏 iframe 并触发原生桥 |
| 7 | 混合内容 | 不适用 | 全站 HTTPS 后无混合内容问题 |
| 8 | 长时间内存 | 待真机验证 | `performance.memory` 在 WKWebView 不可用（恒报 0），JS 堆指标弃用，内存监测改用原生侧 phys_footprint 单一数据源 |

## 架构决策（用户已拍板）

**采用方案 A：CA 证书 + MITM（完整能力）。**

- App 首次启动生成设备本地根 CA（Security 框架生成密钥对 + 手工 DER 编码自签证书，存 Keychain）
- 引导用户安装并「完全信任」该 CA（导出 .cer → 系统设置安装描述文件 → 启用完全信任；侧载场景无审核顾虑）
- 本地代理对 `*.kancolle-server.com:443`（及其他需要内容可见的游戏域名）执行 MITM：CONNECT 后向 WKWebView 出示现场签发的站点证书（CA 签名），终止 TLS；上游另起真实 TLS 连接。此后游戏流量对代理完全明文可见
- 资源缓存（任务 8）、main.js 补丁（任务 9）在解密后的明文通道上实施，与原计划一致
- 其余域名（DMM/osapi/广告阻断等）维持 CONNECT 盲隧道，不解密——把 MITM 面缩到最小

## 对计划的变更

- 新增任务 6A（MitmCA：CA 生成/站点证书签发/Keychain）与任务 6B（证书安装引导 + 代理 TLS 终止集成 + MITM 复验），插入任务 6 与任务 7 之间
- 任务 8/9 前提从「明文 HTTP」改为「MITM 解密后的明文」
- 内存监测弃用 JS 堆指标（performance.memory 不可用），仅用原生 phys_footprint（任务 14 相应简化）

## MitmCA iOS 宿主冒烟（任务 6A）

- 使用带 App entitlement 的 `KanColle.Game` 模拟器构建，在 iPhone 17 Pro 模拟器内调用 `MitmCA`。
- 首次生成根 CA、重新实例化读取同一根 CA、签发 `w00g.kancolle-server.com` 站点证书均成功。
- 冒烟结果：`PASS root=789 site=844`；随后已移除临时启动钩子，未把测试探针留在正式源码中。
- 说明：无宿主的 iOS 命令行测试 bundle 会因缺少 Keychain entitlement 返回 `errSecMissingEntitlement (-34018)`；因此 iOS Keychain 行为必须在已签名 App 宿主中验证。macOS `swift test` 继续负责纯逻辑与 Keychain 持久化回归测试。

## MITM 端到端复验（任务 6B）

- 在 iPhone 模拟器安装并完全信任 App 导出的根 CA。
- DMM 游戏页加载后，代理日志出现 `[KC] GET/POST ...kancolle-server.com`，证明 HTTPS CONNECT 已由本地 TLS 会话终止并成功解密。
- JS 桥同时捕获 `/kcsapi/api_start2/get_option_setting`，证明 iframe 注入与解密后的游戏请求均正常。
- 非游戏域名和关闭 MITM 的情况继续使用 CONNECT 盲隧道；MITM 范围严格限制在 `kancolle-server.com` 及其子域名。
- 自动验证：GameCore 68 项测试全部通过，iOS Simulator `xcodebuild` 成功。
