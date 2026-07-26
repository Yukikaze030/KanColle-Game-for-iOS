# 当前剩余功能与任务

更新日期：2026-07-26  
依据：`handoff-to-codex.md`、P1/P2/P3 验收记录、总设计规格与当前源码。

> `handoff-to-codex.md` 的任务状态停留在 P1 Spike 后，已经过期。当前实际状态是：
> P1–P3 的主要代码和自动化测试已经交付，但仍有真机验收与若干未闭环项；P4
> 除 FPS 解锁外基本尚未开始。

## P0：先保证真实游戏稳定和数据正确

- [ ] **DMM 真机端到端验收**
  - 自动填充后进入母港。
  - 登录后横屏、1200×720 画面和触控坐标正确。
  - 悬浮球及舰队/战斗/任务 HUD 收到实时 API。
  - 连续游玩至少 30 分钟，验证内存告警、白屏恢复和会话连续性。
  - 证据：`docs/superpowers/p1-acceptance.md` 的真机项目仍为待验收。

- [ ] **解除“稳定盲隧道”与资源功能之间的冲突**
  - DMM 默认关闭 MITM 才稳定，但资源缓存、资源替换、Gadget URL 改写和语音
    请求字幕识别仍依赖代理看到 HTTPS 明文。
  - 优先把可行功能迁移为 WKUserScript/WKURLSchemeHandler/页面内资源观察，避免
    再把 MITM 设为默认。
  - 证据：`Game/RootView.swift`、`Packages/GameCore/Sources/GameCore/ResourceCache.swift`。

- [ ] **中断战斗恢复语义**
  - `restoredIncomplete` 战斗不能作为正在进行的实时战斗直接展示；覆盖页需要显示
    “上次中断记录”或清除当前战斗。
  - 证据：`Packages/GameCore/Sources/GameCore/P3/Persistence/P3SnapshotStore.swift`、
    `Game/P2/GameDataCoordinator.swift`。

- [ ] **持久化失败不能阻断当次 UI 更新**
  - SQLite 保存失败应记录诊断，但仍发布本次舰队/战斗/任务状态并继续处理后续 API。
  - 证据：`Game/P2/GameDataCoordinator.swift` 当前把保存和 `publishCombined` 放在
    同一个 `do/catch` 中。

## P1：P1–P3 已有功能的闭环

- [ ] 资源下载失败重试、退避和用户提示；当前 `downloadRetry` 只存储设置。
- [ ] Widget 写入后主动 `reloadTimelines`、点击深链到舰队页、补充舰队摘要。
- [ ] 通知设置运行时刷新，并显示系统 pending 数量及本 App 占用数量。
- [ ] 大破过滤设置接入 UI 和 `FleetWarningEvaluator`：
  `heavyDamageLockedOnly`、`heavyDamageMinimumLevel`。
- [ ] 接通当前只有设置、没有业务效果的 P3 开关：
  战斗覆盖自动刷新、敌方装备详情、任务完成提示。
- [ ] 战斗结果页补充 MVP、经验、掉落舰和掉落道具摘要。
- [ ] 实现海域血条面板和独立陆航面板。
- [x] 设置页展示 App 主进程内存峰值/采样历史；补 committed navigation、
  SSL/网络错误提示。WebContent 终止后不再静默自动刷新，由用户确认后以
  WebGL + 关闭 FPS 的稳定模式重建，避免无提示地离开当前游戏进度。受 iOS
  公共 API 限制，独立 WebContent 进程无法直接读取内存。
- [ ] iPad 实现“游戏画面 + 工具面板”并排，而不只是全屏覆盖页内部双栏。
- [ ] 完成 OOI/kancolle.moe、截图、字幕、通知、Widget/App Group 的真机验收。
- [ ] 静态数据和应用资源更新器：离线母数据、多语言舰娘/装备、改修、经验和海图数据。

## P2：P4 工具与 Mod

- [ ] 明石改修工厂。
- [ ] 舰娘列表、详情、筛选和排序。
- [ ] 装备列表、详情和筛选。
- [ ] 经验计算器。
- [ ] 远征一览表。
- [ ] 掉落日志。
- [ ] 资源日志和原生图表。
- [ ] 建造/开发结果展示。
- [ ] 数据备份与恢复。
- [ ] 妖精皮肤下载。
- [ ] poi-statistics 可选上报。
- [x] FPS 解锁：CreateJS `Ticker.RAF`，支持默认盲隧道下的 iframe 注入。
- [ ] 暴击显示 Mod。
- [ ] KCCP 英文/印尼文翻译补丁。
- [ ] Kantai3D 陀螺仪视差 Mod。
- [ ] App UI String Catalog 与多语言界面。
- [ ] 应用版本及静态资源在线更新。
