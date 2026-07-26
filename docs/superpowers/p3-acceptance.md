# P3 战斗与任务验收记录

日期：2026-07-26  
工程：`/Users/haozhe/WorkTest/Game`  
分支：`p1-browser-core`

## 1. 交付范围

P3 计划中的 16 项任务已经完成代码交付：

1. 战斗端点、舰队、会话和阶段模型
2. 航空基地、航空战、支援、开幕雷击和雷击解析
3. 先制反潜、炮击、友军、夜战解析
4. 通常/联合舰队阶段顺序与会话 reducer
5. 损管、女神、退避与返航风险
6. 战果评级预测和服务器结果合并
7. 受限战斗摘要及最多 100 场日志投影
8. 任务定义、列表同步和日本时间重置
9. 基础任务事件路由与精确计数
10. 节点、战果、敌舰种和舰队编成条件
11. P3 SQLite 原子持久化与损坏隔离
12. P2/P3 单次 envelope 解析、数据管线和可观察状态接线
13. iPhone 优先、iPad 自适应的原生战斗覆盖页
14. iPhone 优先、iPad 分栏的原生任务覆盖页
15. 设置、受限诊断和功能开关
16. 自动化回归、模拟器启动及本文档

## 2. 自动化验收

### GameCore

命令：

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

结果：

- 282 项测试
- 0 failure
- 覆盖 P1、P2、P3 回归
- 覆盖普通/联合/敌联合、昼夜连续、损管、评级、任务重置、幂等和 SQLite

### iOS App

命令：

```bash
cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme Game \
  -destination 'generic/platform=iOS Simulator' build
```

结果：`BUILD SUCCEEDED`

### WidgetKit

命令：

```bash
cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme GameTimersWidget \
  -destination 'generic/platform=iOS Simulator' build
```

结果：`BUILD SUCCEEDED`

### 模拟器冒烟

- 设备：iPhone 17 Simulator
- 安装：成功
- Bundle ID：`KanColle.Game`
- 启动：成功
- 入口页连接器、钥匙串状态、设置入口和开始游戏按钮正常显示
- `quest_track.json`、`quests-scn.json` 已确认打入 App bundle

## 3. 数据与隐私验收

- P3 fixture 数据文件扫描：未发现 `api_token`、`member_id`、`login_id`、`password`、`nickname`
- 测试源码中仅存在用于验证脱敏的虚拟 `api_token=secret`
- `APIEnvelopeParser` 在进入 reducer 前删除 `api_token`
- `BattleLogEntry` 不包含请求 body、原始响应、token、昵称或 member id
- 诊断导出仅包含 endpoint path、revision、warning、评级偏差和数据库大小
- DMM/第三方连接器账号密码继续仅保存在 Keychain

## 4. WebView 与内存边界

- 战斗、任务、舰队、工具和设置页面均为 SwiftUI 原生页面
- 打开任何覆盖页不会创建第二个 `WKWebView`
- API JSON 仅在管线边界解析，SwiftUI `body` 不解析 JSON
- 战斗阶段 UI 使用最多 32 条摘要；日志存储上限 100 场，默认显示/保留 50 场
- 默认 Canvas 渲染器、原生内存监测、WebContent 终止恢复和 WebGL context 恢复保持启用

## 5. 已验证的关键行为

- endpoint 对应显式阶段计划，不依赖 JSON key 顺序
- 同一 response event ID 不重复扣血或重复增加任务计数
- 夜战 continuation 复用昼战结束 HP
- 主力/护卫和敌联合目标使用集中索引模型
- 普通损管恢复 `floor(maxHP × 20%)`，女神恢复满血，每舰每场一次
- 退避舰不会触发返航大破警告
- 未知敌方 HP 不强行预测精确评级
- 服务器评级到达后优先展示服务器结果，预测偏差仅写受限诊断
- 日本时间每日 05:00、周一、月初和季度重置已测试
- 未知任务保持 `serverOnly`，不会伪造精确进度
- P3 数据库 revision 不倒退；损坏单条 payload 不影响其他数据恢复

## 6. 真机发布前检查

以下项目依赖 Apple Developer 签名或真实游戏会话，不能由无签名 Simulator 完全替代：

1. 为 `KanColle.Game`、`KanColle.Game.Widget` 启用
   `group.KanColle.Game.shared` App Group。
2. 在 iPhone 真机安装并完全信任本地根证书。
3. 使用真实会话核对普通战、联合战、昼转夜、损管和任务 counter。
4. 连续进行至少 5 场战斗，确认 WebContent 内存无持续无界增长。
5. 在 iPad Split View 和全屏分别确认战斗/任务分栏。

上述项目属于签名、服务器和设备验收，不是当前编译或单元测试失败。

## 7. 结论

P3 功能实现、自动化测试、iOS/Widget 编译和 Simulator 启动验收通过。
进入真机发布前，只剩第 6 节所列的账号、证书、签名和真实游戏会话检查。
