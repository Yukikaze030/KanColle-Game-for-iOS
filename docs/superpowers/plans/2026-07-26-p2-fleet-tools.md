# P2 舰队与计时工具详细实现计划

> **执行方式：** 按任务顺序实施；每个任务先写失败测试，再做最小实现，运行该任务列出的测试和 App 构建，成功后单独提交。推荐使用子代理驱动，但共享工作区中同一时刻只能有一个代理修改同一文件。本文只规划 P2，不包含 P3 战斗推演和任务追踪。

- 日期：2026-07-26
- 工程：`/Users/haozhe/WorkTest/Game`
- 规格：`docs/superpowers/specs/2026-07-25-kcanotify-gotobrowser-ios-design.md`
- Android 参考：`/Users/haozhe/GitHub/kcanotify-master`
- 目标：完成 DataPipeline、母港/舰队状态、舰队指标、大破与补给警告、远征/入渠/士气/明石计时、本地通知、SQLite 恢复、舰队覆盖层和 WidgetKit 小组件。
- 设备顺序：**先保证 iPhone 横屏覆盖层，再做 iPad 自适应；不得为了 iPad 推迟 iPhone 可用版本。**
- 技术约束：Swift 5.9、SwiftUI、Observation/Combine、Foundation、SQLite3、UserNotifications、WidgetKit、AppIntents；**只用 Apple 原生 API，不引入 GRDB 或其他第三方依赖。**

---

## 1. P2 范围和完成定义

P2 完成后，登录游戏并进入母港时应具备以下行为：

1. `JSBridge` 捕获的 `/kcsapi/...` 消息进入单一 DataPipeline；`svdata=`、无前缀 JSON、表单请求体、错误 envelope 都有明确处理结果。
2. `/api_start2` 或 `/api_start2/getData` 建立舰娘、装备、远征母数据索引；`/api_port/port` 建立用户舰娘、用户装备、舰队、入渠、资源和提督基础状态。
3. 后续 deck、ship、slot、补给、编成、入渠、远征返回等增量端点不会要求重新进入母港才能刷新状态。
4. 舰队覆盖层显示四舰队的成员、等级、HP、cond、补给、远征状态、索敌、制空，并在大破/未补给时给出明显但不遮挡游戏的警告。
5. 远征、入渠、士气恢复、明石修理计时可持久化；App 被系统终止并重启后可恢复最近快照，收到新 `port` 后以服务器状态覆盖旧快照。
6. 本地通知通过 `UNUserNotificationCenter` 调度，稳定 identifier 去重，只保留每个计时器最近一条，并确保全应用 pending request 不超过 iOS 的 64 条限制。
7. WidgetKit 在主屏幕显示最近计时器和舰队摘要；App 未运行时读取最后一次 SQLite 快照，点击可深链回舰队覆盖层。
8. P1 浏览器、字幕、截图、白屏恢复、资源缓存保持可用；P2 解析错误不能中断游戏加载。

### 明确不包含

- P3 的 `KcaBattle` 战斗逐阶段推演、战斗预测 UI、任务追踪。
- P4 的掉落/资源图表、舰娘/装备完整图鉴、改修工厂和 poi 上报。
- Android VPN、悬浮窗 Service、AlarmManager、ContentProvider。

---

## 2. 参考源码读取清单

执行任何算法移植前必须对照以下文件，不能凭记忆重写：

| 领域 | Android 文件 | P2 关注内容 |
|---|---|---|
| API 分发 | `KcaService.java` | `API_START2`、`API_PORT`、deck/ndock/ship/slot/charge/nyukyo/hensei/mission 分支及请求参数 |
| 母数据/用户数据 | `KcaApiData.java` | `getKcGameData`、`getPortData`、用户舰娘/装备更新规则、远征名称和时长 |
| 舰队计算 | `KcaDeckInfo.java` | Formula 33 索敌、装备改修索敌、制空熟练度、cond、大破/损管、未补给、明石旗舰判断 |
| 入渠 | `KcaDocking.java` | 四渠状态、完成时刻、修理时间公式 |
| 远征 | `KcaExpedition2.java` | 第 2–4 舰队、取消/返回、任务编号格式化、完成时刻 |
| 士气 | `KcaMoraleInfo.java` | `WAIT_UNIT = 179000`、每 3 cond 恢复、registered time 规则 |
| 明石 | `KcaAkashiRepairInfo.java` | 明石/明石改旗舰、修理设施数量、20 分钟周期 |
| 通知 | `KcaAlarmService.java` | 远征/入渠/士气/明石通知文案、提前量、去重意图 |

执行前快速定位命令：

```bash
rg -n "API_START2|API_PORT|API_GET_MEMBER_DECK|API_GET_MEMBER_NDOCK|API_REQ_HOKYU_CHARGE|API_REQ_NYUKYO|API_REQ_HENSEI|API_REQ_MISSION" \
  /Users/haozhe/GitHub/kcanotify-master/app/src/main/java/com/antest1/kcanotify/KcaService.java \
  /Users/haozhe/GitHub/kcanotify-master/app/src/main/java/com/antest1/kcanotify/KcaConstants.java
rg -n "getEachSeekValue|getEquipSeek|getAirPowerRange|checkHeavyDamageExist|checkMinimumMorale|checkAkashiFlagship" \
  /Users/haozhe/GitHub/kcanotify-master/app/src/main/java/com/antest1/kcanotify/KcaDeckInfo.java
```

---

## 3. P2 目标架构

```text
JSBridge.Event.kcsapi
  -> GameDataPipeline actor
       -> APIEnvelopeParser
       -> APIEndpointRouter
       -> MasterDataReducer / PortStateReducer / IncrementalStateReducer
       -> GameStateSnapshot（值类型、revision 单调递增）
       -> FleetCalculator / TimerProjector
       -> SnapshotStore（SQLite 单事务）
       -> NotificationPlan（纯逻辑）
  -> @MainActor GameStateModel
       -> FleetOverlayView / TimerOverlayView / warning banner
  -> NotificationService（UNUserNotificationCenter）
  -> WidgetCenter.reloadTimelines
```

### 并发原则

- JSON 解析、reducer、SQLite 写入在 `GameDataPipeline actor` 内串行执行，保证消息顺序和 revision 单调。
- UI 只观察 `@MainActor GameStateModel` 发布的不可变 `GameStateSnapshot`，不直接读写 SQLite。
- 通知调度和 Widget 刷新基于已提交的 snapshot；写库失败时 UI 仍可更新，但必须记录诊断，不能阻断下一条 API。
- 所有时间在 Core 中存 `Date`/Unix 毫秒；显示时才使用用户当前 Calendar/Locale。

### 计划新增文件结构

```text
Packages/GameCore/Sources/GameCore/P2/
  API/APIEnvelope.swift
  API/APIEnvelopeParser.swift
  API/APIEndpoint.swift
  API/FormBodyParser.swift
  Model/MasterModels.swift
  Model/PortModels.swift
  Model/GameStateSnapshot.swift
  Pipeline/GameDataPipeline.swift
  Pipeline/MasterDataReducer.swift
  Pipeline/PortStateReducer.swift
  Pipeline/IncrementalStateReducer.swift
  Fleet/FleetCalculator.swift
  Fleet/FleetWarningEvaluator.swift
  Timer/TimerProjector.swift
  Persistence/GameSnapshotStore.swift
  Notification/NotificationPlanner.swift

Packages/GameCore/Tests/GameCoreTests/P2/
  Fixtures/README.md
  Fixtures/envelope_*.txt
  Fixtures/start2_minimal.json
  Fixtures/port_normal.json
  Fixtures/port_edge_cases.json
  Fixtures/deck_expedition.json
  Fixtures/ndock_active.json
  Fixtures/charge.json
  Fixtures/hensei_change.json
  Fixtures/nyukyo_start.json
  Fixtures/mission_return.json
  Fixtures/fleet_formula33.json
  Fixtures/fleet_airpower.json
  Fixtures/fleet_warning.json
  APIEnvelopeParserTests.swift
  MasterDataReducerTests.swift
  PortStateReducerTests.swift
  IncrementalStateReducerTests.swift
  FleetCalculatorTests.swift
  FleetWarningEvaluatorTests.swift
  TimerProjectorTests.swift
  GameSnapshotStoreTests.swift
  NotificationPlannerTests.swift

Game/P2/
  GameStateModel.swift
  GameDataCoordinator.swift
  NotificationService.swift
  SharedContainer.swift
  DeepLinkRouter.swift
Game/Fleet/
  FleetOverlayView.swift
  FleetCardView.swift
  ShipStatusRow.swift
  FleetWarningBanner.swift
  TimerOverlayView.swift
Game/Settings/
  NotificationSettingsSection.swift

GameWidget/
  GameWidgetBundle.swift
  FleetTimerWidget.swift
  FleetTimerProvider.swift
  GameWidget.entitlements
```

---

## 4. Fixture 规范

所有解析和算法任务使用仓库内固定 fixture，禁止单元测试访问线上游戏服务器。

1. fixture 从开发者自己的游戏消息或 Android 错误日志提取时，先移除 `api_token`、`api_verno`、member id、昵称、服务器 IP、Cookie、Authorization；舰娘实例 id 重新映射为连续测试 id。
2. `start2_minimal.json` 只保留测试所需舰娘、装备、远征，避免把整份大型母数据提交到测试目录。
3. 原始响应文件保留外层 `svdata=` 的测试样本；业务 reducer fixture 保存解包后的 `api_data`，避免每个 reducer 测试重复测试 envelope。
4. `Fixtures/README.md` 记录每个 fixture 的来源 API、删改字段和期望用途；不得包含账号或令牌。
5. 金值必须来自 Android 公式的独立计算或在 Android 参考实现中用相同 fixture 跑出的结果，不能把 Swift 当前输出直接回写成预期值。

敏感字段检查命令：

```bash
rg -n 'api_token|Cookie|Authorization|api_member_id|api_nickname|login_id|password' \
  /Users/haozhe/WorkTest/Game/Packages/GameCore/Tests/GameCoreTests/P2/Fixtures
```

预期：只允许 `README.md` 中说明禁用字段的文字命中，JSON/TXT fixture 不得命中。

---

## 5. 通用验证命令

每个任务结束必须执行：

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme Game \
  -destination 'generic/platform=iOS Simulator' build

git diff --check
```

Widget target 创建后，额外执行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme GameWidgetExtension \
  -destination 'generic/platform=iOS Simulator' build
```

失败处理：先修复当前任务，不通过不得进入下一任务，不以跳过测试或删除断言作为修复。

---

## 任务 1：API envelope、表单请求解析与端点路由

**目标：** 把 JSBridge 的字符串消息转换为有界、可诊断、可路由的 API 事件；错误数据不崩溃且不进入状态 reducer。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/API/APIEnvelope.swift`
- 创建：`Packages/GameCore/Sources/GameCore/P2/API/APIEnvelopeParser.swift`
- 创建：`Packages/GameCore/Sources/GameCore/P2/API/APIEndpoint.swift`
- 创建：`Packages/GameCore/Sources/GameCore/P2/API/FormBodyParser.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/APIEnvelopeParserTests.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/APIEndpointTests.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/Fixtures/README.md`
- 创建 fixture：`envelope_valid_svdata.txt`、`envelope_valid_plain.txt`、`envelope_api_error.txt`、`envelope_malformed.txt`、`request_form_encoded.txt`

**测试 fixture 与断言：**

- `svdata={"api_result":1,"api_data":...}` 和纯 JSON 都成功。
- UTF-8 BOM/首尾空白允许；HTML、空字符串、非法 UTF-8、超过 16 MiB、JSON 顶层非对象拒绝。
- `api_result != 1` 产出 typed server error，保留有限长度 `api_result_msg`，不暴露原始令牌。
- endpoint 只根据 URL path 路由，去掉 query/fragment；`/evil?next=/api_port/port` 不得识别为 port。
- `application/x-www-form-urlencoded` 正确处理 `+`、百分号、重复 key；坏百分号返回错误而不是静默错误值。
- 定义 P2 端点 enum：start2、port、deck、shipDeck、ship2、ship3、slotItem、charge、henseiChange、henseiPreset、missionReturn、missionResult、ndock、nyukyoStart、nyukyoSpeedchange、itemuseCond、unknown。

**实现要求：**

- 使用 `Data` + `JSONSerialization`/`JSONDecoder`；不得使用正则解析 JSON。
- `APIEnvelope` 保存 endpoint、request parameters、`apiData` 和接收时间；未知字段容忍。
- parser 错误枚举可写入 `DiagnosticsStore`，但 Core 不依赖 App target。
- 解析上限必须与现有 JSBridge 16 MiB 响应限制一致。

**验证：**

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'APIEnvelopeParserTests|APIEndpointTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Game.xcodeproj -scheme Game -destination 'generic/platform=iOS Simulator' build
git diff --check
```

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/API Packages/GameCore/Tests/GameCoreTests/P2
git commit -m "feat(p2): API envelope 解析与端点路由"
```

---

## 任务 2：母数据模型与 `/api_start2` reducer

**目标：** 建立计算舰队指标所需的最小强类型母数据索引，不把 Android 的全局静态 Map 搬进 Swift。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Model/MasterModels.swift`
- 创建：`Packages/GameCore/Sources/GameCore/P2/Pipeline/MasterDataReducer.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/MasterDataReducerTests.swift`
- 创建 fixture：`Fixtures/start2_minimal.json`

**模型最小字段：**

- `MasterShip`：id、name、stype、fuelMax、ammoMax、slotCapacity、speed。
- `MasterSlotItem`：id、name、type2、search、antiAir、accuracy、antiSub、range 等 P2 计算字段。
- `MasterMission`：id、name、durationMinutes。
- `MasterCatalog`：三个 `[Int: Model]` 字典、sourceVersion、loadedAt；字典替换必须是一次原子 reducer 操作。

**测试 fixture 与断言：**

- 包含普通舰、明石/明石改、带不同 `api_type[2]` 的舰载机、损管、舰艇修理设施和两条远征。
- 重复 id 采用响应中最后一个有效对象并记录 warning；缺少 id 的条目忽略。
- 未知新字段不失败；关键数组缺失时返回空索引但不破坏上一次有效 catalog。
- `/api_start2` 和 `/api_start2/getData` 结果相同。
- 远征时长按 Android `api_time` 的分钟语义转换，不在 model 内预先减通知提前量。

**实现要求：**

- reducer 为纯函数：`reduce(previous:envelope:) -> Reduction<MasterCatalog>`，便于失败时保留旧状态。
- 不把整个 start2 JSON 永久驻留内存；解析完成后只保留 P2 字段。
- 类型常量集中定义并注明对应 `KcaApiData`/`KcaDeckInfo` 常量来源。

**验证：** 使用通用验证命令，额外先跑：

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MasterDataReducerTests
```

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Model/MasterModels.swift \
        Packages/GameCore/Sources/GameCore/P2/Pipeline/MasterDataReducer.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/MasterDataReducerTests.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/Fixtures/start2_minimal.json
git commit -m "feat(p2): 建立舰 C 母数据索引"
```

---

## 任务 3：母港状态模型与 `/api_port/port` 全量 reducer

**目标：** 用一次 port 响应建立 P2 的单一事实来源，并明确服务器全量状态覆盖本地快照的规则。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Model/PortModels.swift`
- 创建：`Packages/GameCore/Sources/GameCore/P2/Model/GameStateSnapshot.swift`
- 创建：`Packages/GameCore/Sources/GameCore/P2/Pipeline/PortStateReducer.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/PortStateReducerTests.swift`
- 创建 fixture：`Fixtures/port_normal.json`、`Fixtures/port_edge_cases.json`

**状态模型：**

- `AdmiralState`、`ResourceState`。
- `OwnedShip`：实例 id、master id、level、now/max HP、cond、fuel/ammo、slots、extra slot、onSlot、search、locked。
- `OwnedSlotItem`：实例 id、master id、level、aircraftLevel、locked。
- `Fleet`：1-based API id 转换后的稳定 `FleetID(0...3)`、name、ship instance ids、mission tuple。
- `Dock`：0-based id、state、ship id、completion date。
- `GameStateSnapshot`：master、port、timer projection、revision、serverUpdatedAt、isRestored。

**测试 fixture 与断言：**

- 四舰队、空位 `-1`、七舰编成、四入渠、执行中远征、空闲远征、完整用户装备。
- 字段缺失、负 HP、nowHP 大于 maxHP、重复 ship id、舰队引用不存在舰娘时做安全归一化并记录 warning。
- 新 port 是服务器权威全量：删除响应中已不存在的用户舰娘和舰队引用；revision 只在成功提交后加一。
- 收到 port 前允许 master 未加载；此时保留 master id，指标显示 unknown，随后 start2 到达可重算。
- timestamp 使用注入 clock，测试不依赖当前时间。

**实现要求：**

- 值类型、`Sendable`、`Codable`；UI 不持有原始 JSON。
- 解析失败时返回 previous snapshot，不发布半成品。
- HP/cond 等服务端值不擅自修改；显示层可以 clamp 百分比。

**验证：** 使用通用验证命令，额外先跑 `swift test --filter PortStateReducerTests`。

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Model/PortModels.swift \
        Packages/GameCore/Sources/GameCore/P2/Model/GameStateSnapshot.swift \
        Packages/GameCore/Sources/GameCore/P2/Pipeline/PortStateReducer.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/PortStateReducerTests.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/Fixtures/port_*.json
git commit -m "feat(p2): 建立母港与舰队全量状态"
```

---

## 任务 4：增量 API reducer 与状态一致性

**目标：** 移植 `KcaService` 对 P2 相关端点的增量更新，避免每次操作后等待下一次 port。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Pipeline/IncrementalStateReducer.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/IncrementalStateReducerTests.swift`
- 创建 fixtures：`deck_expedition.json`、`ndock_active.json`、`charge.json`、`hensei_change.json`、`hensei_preset.json`、`nyukyo_start.json`、`nyukyo_speedchange.json`、`mission_return.json`、`itemuse_cond.json`、`ship_deck.json`

**端点和更新规则：**

- `api_get_member/deck`：替换舰队和远征 tuple。
- `api_get_member/ship_deck`、`ship2`、`ship3`：更新返回的用户舰娘与 deck，不删除未返回舰娘，除非该 API 明确为全量。
- `api_get_member/slot_item`：替换用户装备全量。
- `api_req_hokyu/charge`：更新返回舰娘燃料/弹药/舰载机数。
- `api_req_hensei/change`、`preset_select`：依据 request body 调整编成；处理 `api_ship_id=-1/-2` 的移除语义和跨舰队移动。
- `api_get_member/ndock`：替换四渠状态。
- `api_req_nyukyo/start`：依据 deck/request 建立入渠；高速修复时立即恢复 HP 并清空渠位。
- `api_req_nyukyo/speedchange`：清空指定渠并恢复对应舰娘 HP。
- `api_req_mission/return_instruction`：把对应远征标记取消并更新新到达时间。
- `api_req_mission/result`：清除对应舰队远征。
- `api_req_member/itemuse_cond`：更新对应舰队 cond，并触发士气投影重算。

**测试重点：**

- 消息按顺序应用；用 revision 验证同一输入不会应用两次（pipeline event id 去重仅限当前进程的小型 LRU）。
- request 参数缺失、索引越界、未知舰娘只产生 warning，不崩溃、不破坏其他舰队。
- port → 编成变更 → 补给 → 入渠 → 高速修复 → mission result 的完整序列最终状态金值固定。
- 未知 endpoint 明确返回 `.ignored`，不得增加 revision 或触发持久化/通知。

**验证：** 使用通用验证命令，额外先跑 `swift test --filter IncrementalStateReducerTests`。

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Pipeline/IncrementalStateReducer.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/IncrementalStateReducerTests.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/Fixtures
git commit -m "feat(p2): P2 游戏状态增量 reducer"
```

---

## 任务 5：舰队索敌、制空和士气计算

**目标：** 逐式移植 `KcaDeckInfo` 的 P2 舰队指标，纯函数计算并由固定 fixture 验证。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Fleet/FleetCalculator.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/FleetCalculatorTests.swift`
- 创建 fixtures：`fleet_formula33.json`、`fleet_airpower.json`、`fleet_morale.json`

**实现分块：**

1. **Formula 33 索敌：** 舰娘裸索敌、装备系数、改修加成、提督等级修正、空位修正；支持 Cn=1/2/3/4 和纯索敌模式。
2. **装备索敌改修：** 对照 `getEquipSeek(itemType,itemSeek,itemLevel)` 的每类装备系数，不用一张未经验证的通用乘数表。
3. **制空范围：** 基础 `floor(antiAir * sqrt(slot))`、装备改修、熟练度内外部加成区间，普通槽和增设槽语义与 Android 一致。
4. **士气：** 每舰 cond 状态、舰队最低 cond；阈值默认 40，但从设置注入；恢复时间算法单独放任务 6。
5. **退避/排除：** 计算 API 支持按舰队成员位置排除，给 P3 联合舰队复用；P2 UI 默认不排除。

**fixture 金值：**

- 至少一个无装备舰队、一个带侦察机/电探改修舰队、一个含空位/不存在装备舰队。
- 制空覆盖 0 槽、普通熟练度、满熟练度、改修、非舰载机错误输入。
- Formula 33 所有 Cn 各有断言，浮点比较使用明确 tolerance（例如 `1e-6`），不先四舍五入。
- 与 Android `KcaDeckInfo` 对同 fixture 的输出逐项记录在 `Fixtures/README.md`。

**验证：** 使用通用验证命令，额外先跑 `swift test --filter FleetCalculatorTests`。

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Fleet/FleetCalculator.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/FleetCalculatorTests.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/Fixtures/fleet_*.json
git commit -m "feat(p2): 舰队索敌制空与士气计算"
```

---

## 任务 6：大破、损管、未补给与明石警告

**目标：** 复刻出击前最关键的安全提示，并使规则可配置、可单测。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Fleet/FleetWarningEvaluator.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/FleetWarningEvaluatorTests.swift`
- 创建 fixture：`Fixtures/fleet_warning.json`
- 修改：`Packages/GameCore/Sources/GameCore/SettingsStore.swift`
- 修改：`Packages/GameCore/Tests/GameCoreTests/SettingsStoreTests.swift`

**规则：**

- 大破：`nowHP * 4 <= maxHP`，避免浮点误差。
- 装备损管：普通槽和增设槽均检查 type2=`T2_DAMECON`；状态区分 `.none`、`.heavyWithDamecon`、`.heavyWithoutDamecon`。
- 入渠中的舰娘不参与大破出击警告，但仍在舰队 UI 显示“入渠”。
- 可配置只检查锁定舰/带锁装备舰、最低等级；默认以安全优先，检查全部舰娘且最低等级为 0。
- 补给：用户 fuel/ammo 对比 master fuelMax/ammoMax；母数据缺失时为 `.unknown`，不能误报已补满。
- 明石：旗舰 master id 182/187/985，基础可修数量与舰艇修理设施 type2 对照 Android；只计算当前舰队可修位置，不在 P2 模拟每舰 HP 恢复量。

**测试：**

- HP 恰好 25%、低于/高于边界；maxHP=0 安全处理。
- 普通槽/增设槽损管、空装备、损管母数据缺失。
- 入渠排除、锁定/等级过滤、七舰编成。
- 少 1 点燃料、少 1 点弹药、完全补给、母数据缺失。
- 三个明石 master id、修理设施数量上限、非明石旗舰。

**验证：** 使用通用验证命令，额外先跑：

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'FleetWarningEvaluatorTests|SettingsStoreTests'
```

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Fleet \
        Packages/GameCore/Sources/GameCore/SettingsStore.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/FleetWarningEvaluatorTests.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/Fixtures/fleet_warning.json \
        Packages/GameCore/Tests/GameCoreTests/SettingsStoreTests.swift
git commit -m "feat(p2): 舰队大破补给与明石警告"
```

---

## 任务 7：远征、入渠、士气和明石计时投影

**目标：** 把服务器状态转换为稳定 timer id 和完成时刻，通知、UI、Widget 只消费同一投影结果。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Timer/TimerProjector.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/TimerProjectorTests.swift`
- 创建 fixture：`Fixtures/timer_projection.json`

**模型：**

- `GameTimer.Kind`：expedition、docking、morale、akashi。
- 稳定 id：`expedition.<fleetIndex>`、`docking.<dockIndex>`、`morale.<fleetIndex>`、`akashi`。
- 字段：kind、slot、title、detail、completionDate、sourceRevision、isCancelled。

**规则：**

- 远征只允许第 2–4 舰队；`api_mission[0] != 0` 且 mission/arrive 有效时生成；返回/取消更新同一 id，不叠加旧 timer。
- 入渠 `api_state == 1` 且 ship id/complete time 有效时生成；高速修复和空渠移除。
- 士气严格移植 `KcaMoraleInfo`：`WAIT_UNIT=179 秒`，每 3 cond 一次，`ceil((threshold-cond)/3)`；保留 registered time，cond 下降时重置基准，变高时完成时刻不得错误延后。
- 明石：存在有效明石旗舰时从本次确认时刻开始 20 分钟；旗舰/编成改变时重新投影，移除明石时取消。
- `notificationLeadTime` 只在通知 planner 使用，不修改真实 completionDate；默认 61 秒与 Android 一致，设置允许 0–600 秒。

**测试：**

- 注入固定 clock，覆盖过去时间、未来时间、时钟相同、多次相同 API 幂等。
- cond 39/38/37 和阈值 40 的边界；cond 达阈值移除 timer。
- 四类 timer 的添加、更新、删除 diff。
- 远征取消后新到达时间、任务完成清除、App 恢复后时间仍为绝对时间。

**验证：** 使用通用验证命令，额外先跑 `swift test --filter TimerProjectorTests`。

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Timer \
        Packages/GameCore/Tests/GameCoreTests/P2/TimerProjectorTests.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/Fixtures/timer_projection.json
git commit -m "feat(p2): 远征入渠士气与明石计时投影"
```

---

## 任务 8：SQLite 快照、迁移和恢复

**目标：** 每个成功 revision 原子保存，冷启动可恢复，Widget 可读取；继续使用系统 SQLite3，不引入 GRDB。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Persistence/GameSnapshotStore.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/GameSnapshotStoreTests.swift`
- 创建：`Game/P2/SharedContainer.swift`
- 修改：`Game/Game.entitlements`（若不存在则创建）
- 修改：`Game.xcodeproj/project.pbxproj`（App Group entitlement 与 entitlements 路径）

**数据库位置：**

- App target 通过 `FileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.KanColle.Game.shared")` 取得容器并把 path 注入 Core。
- 单元测试用临时目录，不依赖 entitlement。
- App Group 容器不可用时，App 降级到 Application Support；Widget 显示无数据并记录诊断，不能因此阻止游戏启动。

**schema v1：**

```sql
CREATE TABLE schema_meta (version INTEGER NOT NULL);
CREATE TABLE current_snapshot (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  revision INTEGER NOT NULL,
  updated_at REAL NOT NULL,
  state_json BLOB NOT NULL
);
CREATE TABLE timer_snapshot (
  timer_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  slot INTEGER,
  title TEXT NOT NULL,
  detail TEXT NOT NULL,
  completion_at REAL NOT NULL,
  source_revision INTEGER NOT NULL
);
CREATE INDEX timer_completion_idx ON timer_snapshot(completion_at);
```

`current_snapshot` 与 `timer_snapshot` 必须在同一 `BEGIN IMMEDIATE ... COMMIT` 中替换；开启 WAL、foreign_keys、busy_timeout，prepared statement 全部绑定参数。

**测试：**

- 空库建表、保存/读取、覆盖旧 revision、拒绝 revision 倒退。
- transaction 中途注入失败后仍能读到上一完整 revision。
- 并发 20 次保存最终读到最大 revision，不能出现 `SQLITE_BUSY` 泄漏到调用方。
- JSON 损坏、schema version 过高、只读目录、数据库无法打开均返回 typed error。
- 过期 snapshot 仍可恢复但标记 `isRestored=true/stale=true`；下一次有效 port 覆盖。
- timer 查询按完成时间排序并排除明显过期项；过期清理不删除 current snapshot。

**验证：** 使用通用验证命令，额外先跑 `swift test --filter GameSnapshotStoreTests`。

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Persistence \
        Packages/GameCore/Tests/GameCoreTests/P2/GameSnapshotStoreTests.swift \
        Game/P2/SharedContainer.swift Game/Game.entitlements Game.xcodeproj/project.pbxproj
git commit -m "feat(p2): SQLite 游戏状态快照与恢复"
```

---

## 任务 9：GameDataPipeline 与 App 接线

**目标：** 将现有 `RootView.configureBridge()` 的 kcsapi 分支接入 P2，而不破坏字幕 `api_start2` 消费。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Pipeline/GameDataPipeline.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/GameDataPipelineTests.swift`
- 创建：`Game/P2/GameStateModel.swift`
- 创建：`Game/P2/GameDataCoordinator.swift`
- 修改：`Game/RootView.swift`
- 修改：`Game/Game/GameView.swift`

**实现步骤：**

1. `GameDataPipeline actor.ingest(endpoint:request:response:receivedAt:)`：解析 → 路由 → reducer → timer projection → SQLite save → 发布 snapshot/diff。
2. 失败事件返回结构化 `PipelineDiagnostic`；只把截断后的 endpoint/error 写入 `DiagnosticsStore`，不得落原始 token。
3. `GameDataCoordinator` 在启动时先异步 restore snapshot，再接受新事件；若新 API 已到达，晚返回的旧 restore 不得覆盖更高 revision。
4. `GameStateModel` 在 MainActor 发布 snapshot、lastError、isRestored、fleet summaries。
5. `RootView` 的 `.kcsapi` 同时送字幕和 P2 coordinator；两者互不调用，任何一方失败不阻断另一方。
6. 退出游戏时停止当前 session 的事件接受；SQLite 保留。下一次启动新建 session generation，旧 Task 回调不得污染新 session。

**测试：**

- start2 → port → charge → hensei 的端到端序列。
- malformed 事件夹在两个有效事件中，后一个仍被处理。
- restore race、session generation、未知 endpoint、重复消息。
- fake snapshot store 验证只对成功 revision 保存。

**验证：** 使用通用验证命令，额外先跑 `swift test --filter GameDataPipelineTests`。

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Pipeline \
        Packages/GameCore/Tests/GameCoreTests/P2/GameDataPipelineTests.swift \
        Game/P2/GameStateModel.swift Game/P2/GameDataCoordinator.swift \
        Game/RootView.swift Game/Game/GameView.swift
git commit -m "feat(p2): 接通游戏数据管线与快照恢复"
```

---

## 任务 10：iPhone 优先的舰队/计时覆盖 UI

**目标：** 点击悬浮球“舰队”打开原生 SwiftUI 覆盖层；保持游戏 WebView 存活，关闭后立即回到游戏。

**文件：**

- 创建：`Game/Fleet/FleetOverlayView.swift`
- 创建：`Game/Fleet/FleetCardView.swift`
- 创建：`Game/Fleet/ShipStatusRow.swift`
- 创建：`Game/Fleet/FleetWarningBanner.swift`
- 创建：`Game/Fleet/TimerOverlayView.swift`
- 创建：`Packages/GameCore/Sources/GameCore/P2/Fleet/FleetPresentation.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/FleetPresentationTests.swift`
- 修改：`Game/RootView.swift`
- 修改：`Game/Game/FloatingMenuView.swift`（仅接线，不改现有入口名称）

**iPhone 布局：**

- 仍锁定横屏；覆盖层使用 `sheet`/自定义全屏半透明 overlay，不销毁 `GameView` 或 WKWebView。
- 默认显示舰队横向分页/分段选择；一屏显示舰队摘要和最多 7 艘舰，信息优先级：大破警告 > HP > 远征/士气 > 补给 > 索敌/制空。
- 舰娘行使用颜色+图标+文字三重表达，不能只靠颜色；大破无损管为红色强警告，有损管为橙色。
- Timer 以真实 completionDate 每秒更新显示，UI ticker 不写回状态、不每秒写 SQLite。
- 动态字体、VoiceOver label、44pt 最小点击区；窄屏可滚动，不截断关闭按钮。

**iPad 增强（完成 iPhone 后）：**

- `horizontalSizeClass == .regular` 时左侧舰队列表、右侧详细舰队/计时器；不新增另一套状态逻辑。
- Split View 尺寸变小时回落 iPhone 单列，不依赖固定屏幕宽度。

**测试与手动 fixture：**

- `FleetPresentationTests` 测试空状态、restored/stale 标识、四舰队排序、计时器排序、警告优先级和格式化边界。
- SwiftUI Preview/开发注入使用 `port_normal`、`fleet_warning`、空快照三种状态；Preview fixture 只在 DEBUG 编译。
- 手动：覆盖层打开/关闭 30 次后游戏音频和 WebView 状态不重载；iPhone 横屏无网页其他区域露出；iPad regular/compact 均可操作。

**验证：**

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FleetPresentationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Game.xcodeproj -scheme Game -destination 'generic/platform=iOS Simulator' build
git diff --check
```

**Commit：**

```bash
git add Game/Fleet Game/RootView.swift Game/Game/FloatingMenuView.swift \
        Packages/GameCore/Sources/GameCore/P2/Fleet/FleetPresentation.swift \
        Packages/GameCore/Tests/GameCoreTests/P2/FleetPresentationTests.swift
git commit -m "feat(p2): 舰队与计时覆盖层"
```

---

## 任务 11：通知计划与 `UNUserNotificationCenter` 调度

**目标：** 四类 timer 的通知可授权、去重、更新、取消，并严格遵守 64 条 pending 上限。

**文件：**

- 创建：`Packages/GameCore/Sources/GameCore/P2/Notification/NotificationPlanner.swift`
- 创建：`Packages/GameCore/Tests/GameCoreTests/P2/NotificationPlannerTests.swift`
- 创建：`Game/P2/NotificationService.swift`
- 创建：`Game/Settings/NotificationSettingsSection.swift`
- 修改：`Packages/GameCore/Sources/GameCore/SettingsStore.swift`
- 修改：`Packages/GameCore/Tests/GameCoreTests/SettingsStoreTests.swift`
- 修改：`Game/Settings/SettingsView.swift`
- 修改：`Game/P2/GameDataCoordinator.swift`
- 修改：`Game/GameApp.swift`（通知 delegate/deep link，如需要）

**纯逻辑 planner：**

- 输入：当前 timers、当前 pending identifiers、其他模块 pending 数、设置、now。
- 输出：`toAdd`、`toRemove`；稳定 identifier 为 `p2.timer.<timerID>`。
- 每 timer 只留最近一条；更新时间变化时 remove+add 同 identifier。
- fireDate=`completionDate - leadTime`；已过去则不新增，完成后移除。
- 总 pending 上限 64：先保留非 P2 request，再按 fireDate 最近优先为 P2 分配剩余名额；额外保留 4 条安全余量，即默认 P2 使用上限 `max(0, 60 - foreignPendingCount)`。即使测试输入 100 个 timer，最终也不得超过 64。
- planner 绝不删除非 `p2.timer.` 前缀请求。

**原生服务：**

- `NotificationService` 使用 `UNUserNotificationCenter`，只在用户点击设置按钮时请求 authorization，不在冷启动自动弹权限框。
- 使用非重复 `UNCalendarNotificationTrigger`，DateComponents 指定 UTC timeZone，避免夏令时重复时间歧义。
- 分类：远征、入渠、士气、明石；通知点击通过 deep link 打开 App 并展示舰队/计时器覆盖层。
- 用户拒绝权限时 UI 显示“前往系统设置”，pipeline 仍正常运行。
- 每次成功 snapshot 后 debounce 约 300–500ms reconcile，防止同一批 API 高频调用中心。

**设置：**

- 四类通知独立开关，默认开；提前量 0–600 秒，默认 61 秒。
- 文案不得声称通知绝对准时，注明由 iOS 调度。

**测试：**

- 80 个合成 timer + 10 个非 P2 pending，验证总数、最近优先、非 P2 不删除。
- 更新/取消/过期/开关关闭/leadTime 边界/相同 fireDate 稳定排序。
- permission 状态通过协议 fake，不直接在 Core 测试调用系统中心。

**验证：** 使用通用验证命令，额外先跑：

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'NotificationPlannerTests|SettingsStoreTests'
```

实机验收前调试命令（仅 Debug UI 暴露“1 分钟测试通知”，Release 不出现）不能成为单元测试替代。

**Commit：**

```bash
git add Packages/GameCore/Sources/GameCore/P2/Notification \
        Packages/GameCore/Tests/GameCoreTests/P2/NotificationPlannerTests.swift \
        Packages/GameCore/Sources/GameCore/SettingsStore.swift \
        Packages/GameCore/Tests/GameCoreTests/SettingsStoreTests.swift \
        Game/P2/NotificationService.swift Game/P2/GameDataCoordinator.swift \
        Game/Settings/NotificationSettingsSection.swift Game/Settings/SettingsView.swift Game/GameApp.swift
git commit -m "feat(p2): 本地计时通知与 64 条上限调度"
```

---

## 任务 12：WidgetKit 舰队计时小组件

**目标：** 系统桌面显示最近计时器和舰队摘要，主 App 未运行时也可读取最后一次快照。

**文件：**

- 创建：`GameWidget/GameWidgetBundle.swift`
- 创建：`GameWidget/FleetTimerWidget.swift`
- 创建：`GameWidget/FleetTimerProvider.swift`
- 创建：`GameWidget/Info.plist`
- 创建：`GameWidget/GameWidget.entitlements`
- 创建：`Game/P2/DeepLinkRouter.swift`
- 修改：`Game/Info.plist`（URL scheme `kancolle-game`）
- 修改：`Game/Game.entitlements`（相同 App Group）
- 修改：`Game.xcodeproj/project.pbxproj`（Widget Extension target、Embed App Extensions、GameCore 依赖、App Group）
- 修改：`Game/P2/GameDataCoordinator.swift`（成功持久化后 `WidgetCenter.shared.reloadTimelines(ofKind:)`，节流）
- 修改：`Game/RootView.swift`（处理 deep link `kancolle-game://fleet` 与 `...://timers`）

**Widget 设计：**

- 支持 `.systemSmall`、`.systemMedium`；iPhone 优先，iPad 使用同一自适应布局。
- Small：最近一个 timer、完成时间/倒计时、舰队名或舰娘名。
- Medium：最近 3 个 timer + 第一舰队大破/补给摘要。
- 无快照：显示“进入游戏后同步”；快照过旧：显示“数据可能已过期”而不是伪装实时。
- Timeline entries 包含 now、最近 timer fire/completion 节点；最晚每 15 分钟请求刷新，但不承诺系统准时执行。
- Widget 只读 SQLite，连接使用 query-only/busy timeout；遇到写锁或损坏时返回上一次内存 entry/无数据，不修库、不写库。
- 所有刷新均有节流：同 revision 只调用一次 `reloadTimelines`。

**工程配置：**

- App Group：`group.KanColle.Game.shared`，App 与 Widget entitlements 完全一致。
- Widget bundle id：`KanColle.Game.Widget`；deployment target iOS 17。
- 使用 `NSExtensionPointIdentifier = com.apple.widgetkit-extension`。
- 若个人签名 profile 尚未启用 App Group，先在 Signing & Capabilities 给两个 target 添加同一 App Group；不得改成普通 Documents 目录绕过扩展沙盒。

**测试：**

- 将 timeline 选择/格式化纯逻辑放到 GameCore，并新增 `WidgetProjectionTests.swift`：无数据、过期、timer 少于/多于 3、相同时间稳定排序、已过期过滤。
- Core 测试使用临时 SQLite；Widget provider 使用注入 reader，Preview 不读取真实 App Group。
- 模拟器手动：添加 Small/Medium、杀掉 App、确认仍显示快照；点击打开舰队覆盖层；切换系统深/浅色和动态字体。

**验证：**

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WidgetProjectionTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Game.xcodeproj -scheme Game -destination 'generic/platform=iOS Simulator' build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Game.xcodeproj -scheme GameWidgetExtension -destination 'generic/platform=iOS Simulator' build
git diff --check
```

**Commit：**

```bash
git add GameWidget Game/P2/DeepLinkRouter.swift Game/P2/GameDataCoordinator.swift \
        Game/Info.plist Game/Game.entitlements Game/RootView.swift \
        Game.xcodeproj/project.pbxproj \
        Packages/GameCore/Sources/GameCore/P2 \
        Packages/GameCore/Tests/GameCoreTests/P2/WidgetProjectionTests.swift
git commit -m "feat(p2): WidgetKit 舰队计时小组件"
```

---

## 任务 13：P2 验收、回归和交付记录

**目标：** 用自动化和真实设备验证 P2，不在本任务新增功能。

**文件：**

- 创建：`docs/superpowers/p2-acceptance.md`
- 按发现的问题修改：仅限 P2 代码与测试
- 不修改设计范围，不顺手实现 P3/P4。

### 自动化验收

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --parallel

cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme Game \
  -destination 'generic/platform=iOS Simulator' clean build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme GameWidgetExtension \
  -destination 'generic/platform=iOS Simulator' build

git diff --check
```

补充执行 fixture 敏感字段扫描，并把测试数、构建结果、commit 范围写入验收文档。

### iPhone 实机验收（必须）

1. 全新启动，进入 DMM 游戏并到母港；30 秒内舰队页从“等待数据”变为四舰队状态。
2. 对照游戏原画面逐项核对舰娘、等级、HP、cond、燃料/弹药、远征和入渠完成时刻。
3. 用 Android Kcanotify 同账号同一时刻对照至少两支舰队的 Formula 33（Cn 1–4）与制空范围；差异必须记录并有解释。
4. 构造/遇到大破舰：无损管红色、有损管橙色、入渠舰不触发出击警告；补给不足提示正确。
5. 执行补给、换舰、预设编成、入渠、高速修复、远征返回；覆盖层无需重新进母港即可更新。
6. 授权通知，安排 2–5 分钟测试计时；锁屏/杀 App 后验证通知到达、点击打开对应覆盖层。
7. 拒绝通知权限再测试：App 不崩溃，设置页显示正确状态并可跳系统设置。
8. 杀 App 后重启：先显示“已恢复/可能过期”快照，新 port 到达后标识消失且状态刷新。
9. 添加 Small/Medium Widget，杀 App 后仍显示最后快照；点击可深链。
10. 连续游玩至少 30 分钟，P1 白屏恢复、截图、字幕、静音、悬浮球均无回归。

### iPad 验收（iPhone 通过后）

1. 横屏全屏、Split View regular/compact 切换，舰队覆盖层不溢出、不遮住关闭按钮。
2. Small/Medium Widget 正常布局；不要求 iPad 独有功能先于 iPhone 完成。

### 64 条上限验收

- 单元测试必须覆盖 80 个合成 timer。
- Debug 诊断页显示 pending 总数/P2 数量，但不显示通知内容中的敏感数据。
- 实际调度后调用 `getPendingNotificationRequests`，断言总数 `<= 64`，且没有删除非 `p2.timer.` 请求。

### 失败准则

以下任一项未满足，P2 不得标记完成：

- 有效 port 后舰队页仍为空或必须刷新网页才出现。
- 大破无损管被显示为安全。
- 同一 timer 存在重复 pending 通知。
- App/Widget 读取到部分写入或损坏快照导致崩溃。
- pending 本地通知超过 64。
- 打开覆盖层导致 WKWebView 重建、游戏重新登录或网页非游戏区域露出。
- fixture 包含令牌、账号、Cookie 或真实 member id。

**最终 Commit：**

```bash
git add docs/superpowers/p2-acceptance.md
git add -u
git commit -m "test(p2): 完成舰队工具与计时通知验收"
```

---

## 6. 推荐执行顺序与并行边界

严格依赖顺序：

```text
1 API parser
 -> 2 master reducer
 -> 3 port reducer
 -> 4 incremental reducer
 -> 5 fleet calculations
 -> 6 warnings
 -> 7 timer projection
 -> 8 SQLite
 -> 9 pipeline integration
 -> 10 fleet UI
 -> 11 notifications
 -> 12 WidgetKit
 -> 13 acceptance
```

可并行但必须避免同文件冲突：

- 任务 5 与任务 8 可在任务 3 模型稳定后并行；前者只改 `Fleet/`，后者只改 `Persistence/`。
- 任务 10 的纯 UI 文件可与任务 11 的 pure planner 并行，但 `SettingsStore.swift`、`RootView.swift`、`GameDataCoordinator.swift` 由主代理最后串行接线。
- Widget target 的 `project.pbxproj` 修改必须单代理独占，不与其他工程配置任务并行。

每个任务一个 commit，方便回滚；除任务 13 的集中验收外，不做重复全量代码审查，以功能实现、自动化测试和编译通过为优先。

---

## 7. 风险与预案

| 风险 | 预案 |
|---|---|
| 游戏 API 字段变化 | Codable/JSON 解析忽略未知字段；关键字段缺失返回 warning 并保留上一有效状态 |
| JS 消息重复或乱序 | Pipeline actor 串行；session generation + 小型 event LRU；服务器 port 全量状态最终收敛 |
| 大型 port/start2 内存峰值 | Data 上限；只保留 P2 强类型字段；解析后释放原始 JSON；不把原始响应写 SQLite |
| SQLite 与 Widget 并发 | WAL、busy_timeout、原子 transaction；Widget 只读 query-only，失败显示无数据 |
| 通知不准时 | 使用系统本地通知并明确文案；稳定 id 调和，不依赖 App 后台常驻 |
| 64 条限制 | planner 预留 4 条余量，按最近完成优先，只保留每 timer 一条，永不删除其他模块请求 |
| App Group 签名失败 | 同一 capability 配置到 App/Widget；模拟器先验证，实机 profile 补 capability；不改用不安全共享路径 |
| 舰队公式移植偏差 | Android 参考实现 + 固定 fixture 双重金值；每一公式独立测试，不在 UI 中计算 |
| 覆盖 UI 触发 WebView 重建 | `GameView` 保持在 ZStack 下层，覆盖层仅改变 SwiftUI 展示；验收连续开关 30 次 |

---

## 8. P2 最终产物清单

- `GameCore` 中可独立测试的 API parser、reducers、fleet calculators、timer projector、SQLite store、notification planner。
- App 中的 `GameDataCoordinator`、舰队/计时覆盖层、通知设置与服务。
- App + Widget 共用的 App Group SQLite 快照。
- Small/Medium WidgetKit 小组件与深链。
- 脱敏 fixture 和来源说明。
- `docs/superpowers/p2-acceptance.md`，记录自动化、iPhone、iPad、通知和 Widget 结果。

