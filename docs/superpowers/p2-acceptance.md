# P2 舰队与计时工具验收记录

日期：2026-07-26

## 已完成

- WebKit `kcsapi` 消息同时送往字幕和 `GameDataPipeline`，互不阻塞。
- `api_start2`、`api_port/port` 及 P2 增量端点的状态归并、revision 与事件去重。
- 舰队、舰娘、装备、编成、补给、入渠、高速修复、远征和士气状态。
- Formula 33 索敌、制空范围、士气等级纯函数。
- 大破 25% 边界、普通槽/增设槽损管、入渠排除、补给和明石修理位置判断。
- 远征、入渠、士气和明石四类稳定计时器。
- SQLite WAL 原子快照、timer 快照、恢复、过期与损坏隔离。
- iPhone 横屏优先的舰队全屏覆盖页；iPad regular 左右分栏。
- 大破无损管红色强警告；有损管橙色；入渠、未补给与士气文字状态。
- 工具页显示四类计时，`TimelineView` 每秒刷新但不写数据库。
- `UNUserNotificationCenter` 用户主动授权、四类独立开关、提前量和 64 条容量控制。
- WidgetKit 小组件读取 App Group SQLite，Small/Medium 显示最近 1/4 条计时。
- App Group 容器不可用时 App 降级 Application Support，游戏启动不受阻。

## 生命周期与安全

- 每次游戏启动生成 session generation；退出后旧 WebKit 回调不能污染新状态。
- 冷启动先恢复快照，再处理新 API；revision 防止旧快照覆盖新状态。
- API 诊断只记录截断 endpoint/error，不持久化原始 `api_token`。
- 未授权通知时不会自动弹权限框，也不会创建新通知。

## 自动验证

```text
GameCore swift test: 193 tests, 0 failures
Game iOS Simulator xcodebuild: BUILD SUCCEEDED
GameTimersWidget iOS Simulator xcodebuild: BUILD SUCCEEDED
```

覆盖的专项套件包括：

- `IncrementalStateReducerTests`
- `FleetCalculatorTests`
- `FleetWarningEvaluatorTests`
- `TimerProjectorTests`
- `GameSnapshotStoreTests`
- `NotificationPlannerTests`
- 既有 MITM、代理、缓存、脚本、字幕与设置回归测试

## 模拟器冒烟

- 设备：iPhone 17 Pro / iOS 26.5 Simulator
- App 可安装并启动，入口连接器、账号密码、钥匙串选项、设置和开始游戏布局正常。
- 截图：`/tmp/p2-entry.png`

## 仍需真机验证

- 用户根证书安装与“完全信任”后的 HTTPS API 长时间采集。
- DMM 真实账号登录后舰队页面实时数据、通知到达和后台恢复。
- WebContent 进程被系统终止后的自动 reload 与 session 连续性。
- Widget/App Group 需要实际开发者签名能力验证。
