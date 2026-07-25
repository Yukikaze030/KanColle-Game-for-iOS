# P3 战斗预测与任务追踪详细实现计划

> **执行方式：** 优先交付纯逻辑：先完成战斗 API 的逐阶段伤害解析和任务进度 reducer，再做持久化、日志和 UI。每个任务先写失败测试，使用固定 fixture，不访问线上服务器；测试和构建通过后单独提交。推荐子代理并行执行，但共享工作区中同一时刻只能有一个代理修改同一文件。本计划不要求逐任务代码审查，以阶段门禁测试代替高频审查。

- 日期：2026-07-26
- 工程：`/Users/haozhe/WorkTest/Game`
- 规格：`docs/superpowers/specs/2026-07-25-kcanotify-gotobrowser-ios-design.md`
- P2 计划：`docs/superpowers/plans/2026-07-26-p2-fleet-tools.md`
- Android 参考：`/Users/haozhe/GitHub/kcanotify-master`
- 重点参考：`KcaBattle.java`、`KcaQuestTracker.java`、`KcaService.java`、`KcaBattleViewService.java`、`KcaQuestViewService.java`
- 目标：完成战斗会话状态机、全部主要伤害阶段、昼夜战与联合舰队、损管和退避、胜败评级预测、任务列表同步、任务条件进度、战斗/任务日志，以及 iPhone 横屏悬浮球覆盖页。
- 设备顺序：**iPhone 横屏第一，iPad 自适应第二；不得为了 iPad 延迟 iPhone 可用版本。**
- 技术约束：Swift 5.9、SwiftUI、Observation、Foundation、SQLite3；**仅 Apple 原生 API，不引入第三方依赖。**

---

## 1. P3 范围和完成定义

P3 完成后，用户从悬浮球进入“战斗”或“任务”页时应具备以下能力：

1. `GameDataPipeline` 能识别地图、通常舰队、联合舰队、演习、昼战、夜战、空袭战、雷达射击、战斗结果和退避端点。
2. 战斗 reducer 按服务器返回的阶段顺序应用伤害，而不是重新模拟游戏 RNG；每个阶段都能产生可测试的 HP 变化和事件摘要。
3. 支持基地航空、喷气/航空、支援、先制反潜、开幕雷击、炮击、闭幕雷击、友军、夜战；缺失、`null`、短数组和旧格式字段不会崩溃。
4. 通常舰队、我方联合舰队、敌方联合舰队、联合对联合的主/护卫舰队索引映射正确。
5. 损害管制/女神只在沉没时触发一次；退避舰不再参与后续大破警告；战斗结果到达前能显示预测评级和是否建议返航。
6. `/api_get_member/questlist` 同步已接任务；start/stop/clear 正确更新激活状态；进度按日本时间 05:00 的日/周/月/季重置规则持久化。
7. 任务进度至少覆盖出击/胜利/击沉舰种、到达节点、演习、远征、入渠、补给、建造、开发、废弃、改修和近代化改修事件；未知任务保持服务器百分比，不伪造精确计数。
8. 战斗和任务状态分别持久化；App 被终止后可恢复日志与任务进度，但进行中的战斗必须标记为“恢复记录”，不能误当作仍在实时更新。
9. iPhone 横屏覆盖页不遮挡主要游戏操作：战斗页默认紧凑双列，任务页默认单列可滚动；悬浮球始终可关闭覆盖页。iPad 使用更宽分栏但功能一致。
10. P1 浏览器和 P2 舰队/计时功能保持可用；任何 P3 解析错误只写入诊断和受限日志，不中断 WebView。

### 明确不包含

- 依据装备、阵型和随机数主动模拟尚未发生的攻击；P3 的“预测”是根据已收到阶段累计 HP 推算战果。
- P4 的掉落统计、资源图表、图鉴、改修工厂完整资料和 poi-statistics 上报。
- Android Overlay Service、VpnService、AlarmManager、ContentProvider。
- 将 Android 的整个 `KcaBattleViewService` 像素级复刻；只保留信息价值并按 iOS 横屏重新设计。
- 自动点击、自动出击或任何改变游戏请求的功能。

---

## 2. 参考源码读取清单

移植算法前必须对照源码，不能凭字段名猜测：

| 领域 | Android 文件 | P3 关注内容 |
|---|---|---|
| API 分发 | `KcaConstants.java`、`KcaService.java` | `API_BATTLE_REQS`、`API_QUEST_REQS`、请求参数、port/deck 快照注入、任务事件触发点 |
| 战斗状态 | `KcaBattle.java` | 当前海域/节点/舰队、HP 数组、联合舰队、退避、损管、阶段处理顺序 |
| 伤害处理 | `KcaBattle.java` | `reduce_value`、`calculateAirBattle`、`calculateSupportDamage`、`calculateRaigekiDamage`、各类 `calculateHougekiDamage` |
| 评级 | `KcaBattle.java` | `calculateRank`、`calculateLdaRank`、单舰大破等特殊分支 |
| 战斗 UI | `KcaBattleViewService.java` | 舰船/敌舰 HP、阵型、制空、接触、照明、MVP、经验、掉落的展示优先级 |
| 任务状态 | `KcaQuestTracker.java` | SQLite schema、ACTIVE/CND0...CND5、有效期、战斗/节点/通用计数规则 |
| 任务列表 UI | `KcaQuestViewService.java` | 每页 5 项、tab/filter、服务端 `api_list`、进度弹窗 |
| 任务静态数据 | `assets/quest_track.json` | 可追踪任务 id、类型、条件目标和显示单位 |
| 任务翻译 | `assets/quests-{jp,en,ko,scn,tcn}.json` | 名称、说明、本地化 fallback |

快速定位命令：

```bash
rg -n "API_BATTLE_REQS|API_QUEST_REQS|API_REQ_SORTIE|API_REQ_COMBINED|API_REQ_PRACTICE|API_GET_MEMBER_QUEST" \
  /Users/haozhe/GitHub/kcanotify-master/app/src/main/java/com/antest1/kcanotify/KcaConstants.java
rg -n "calculateAirBattle|calculateSupportDamage|calculateRaigekiDamage|calculate.*Hougeki|damecon_calculate|calculateRank|processData" \
  /Users/haozhe/GitHub/kcanotify-master/app/src/main/java/com/antest1/kcanotify/KcaBattle.java
rg -n "addQuestTrack|checkQuestValid|updateIdCountTracker|updateNodeTracker|updateQuestTracker|updateBattleTracker|check_quest_completed" \
  /Users/haozhe/GitHub/kcanotify-master/app/src/main/java/com/antest1/kcanotify/KcaQuestTracker.java
rg -n "questTracker\.update|questTracker\.add|questTracker\.remove|API_GET_MEMBER_QUESTLIST|API_REQ_QUEST" \
  /Users/haozhe/GitHub/kcanotify-master/app/src/main/java/com/antest1/kcanotify/KcaService.java
```

---

## 3. 端点范围与优先级

### 3.1 战斗端点

**航路和会话：**

- `/api_req_map/start`
- `/api_req_map/next`
- `/api_req_map/select_eventmap_rank`
- `/api_req_sortie/goback_port`
- `/api_req_combined_battle/goback_port`

**通常舰队和演习：**

- `/api_req_sortie/battle`
- `/api_req_sortie/airbattle`
- `/api_req_sortie/ld_airbattle`
- `/api_req_sortie/ld_shooting`
- `/api_req_sortie/night_to_day`
- `/api_req_battle_midnight/battle`
- `/api_req_battle_midnight/sp_midnight`
- `/api_req_sortie/battleresult`
- `/api_req_practice/battle`
- `/api_req_practice/midnight_battle`
- `/api_req_practice/battle_result`

**联合舰队和敌联合：**

- `/api_req_combined_battle/battle`
- `/api_req_combined_battle/battle_water`
- `/api_req_combined_battle/airbattle`
- `/api_req_combined_battle/ld_airbattle`
- `/api_req_combined_battle/ld_shooting`
- `/api_req_combined_battle/ec_battle`
- `/api_req_combined_battle/each_battle`
- `/api_req_combined_battle/each_battle_water`
- `/api_req_combined_battle/ec_night_to_day`
- `/api_req_combined_battle/midnight_battle`
- `/api_req_combined_battle/sp_midnight`
- `/api_req_combined_battle/ec_midnight_battle`
- `/api_req_combined_battle/battleresult`

端点 enum 必须允许 unknown，不因游戏新增端点阻断 Pipeline。第一批先实现通常昼战、夜战和联合昼战；其他变体复用相同 phase parser 后补 fixture。

### 3.2 任务端点与事件源

**任务列表生命周期：**

- `/api_get_member/questlist`
- `/api_req_quest/start`
- `/api_req_quest/stop`
- `/api_req_quest/clearitemget`

**进度事件源：**

- 地图和战果：map start/next、sortie/combined/practice result。
- 演习：practice battle/result。
- 远征：`/api_req_mission/start`、`/api_req_mission/result`。
- 入渠/补给：`/api_req_nyukyo/start`、`/api_req_hokyu/charge`。
- 工厂：createitem、destroyitem2、createship、getship、destroyship、remodel_slot。
- 改装：powerup、slotset/slotset_ex、slot_deprive；P3 只处理任务计数所需字段。
- 其他简单计数：按 `KcaService` 中实际 `updateIdCountTracker` 调用清单建立映射，不扫描 URL 文本猜事件。

---

## 4. P3 目标架构

```text
JSBridge.Event.kcsapi
  -> GameDataCoordinator
       -> GameDataPipeline actor
            -> APIEnvelopeParser
            -> P2 Fleet reducer
            -> BattleEndpointRouter
            -> BattleSessionReducer
                 -> BattlePhaseDecoder
                 -> DamageEngine
                 -> DameconResolver
                 -> RankPredictor
            -> QuestEventRouter
            -> QuestProgressReducer
                 -> QuestResetCalendar
                 -> QuestConditionEvaluator
       -> BattleSnapshot / QuestSnapshot（revision 单调递增）
       -> P3SnapshotStore（SQLite 原子事务）
       -> BattleLogProjector / QuestPresentationProjector
  -> @MainActor GameStateModel
       -> BattleOverlayView
       -> QuestOverlayView
       -> FloatingBall menu
```

### 并发和状态原则

- 战斗和任务 reducer 是纯值语义；只有 `GameDataPipeline actor` 有权按 API 到达顺序提交状态。
- 战斗 session 使用独立 `battleRevision`；任务使用 `questRevision`，并继续保留 P2 全局 revision。
- 同一桥接 event ID 只能应用一次。重复战斗响应绝不能重复扣血，重复任务事件绝不能重复计数。
- 收到下一节点或新战斗初始化端点时结束旧 session；夜战延续已有昼战 HP，`sp_midnight` 若自带完整 HP 则可独立初始化。
- JSON 缺字段返回 warning 和部分结果；索引越界、NaN、负伤害、异常大数组不得崩溃。
- UI 读取不可变 snapshot，不直接调用 reducer、SQLite 或 WebKit。

### 计划新增文件结构

```text
Packages/GameCore/Sources/GameCore/P3/
  Battle/
    BattleEndpoint.swift
    BattleModels.swift
    BattlePhase.swift
    BattlePhaseDecoder.swift
    DamageEngine.swift
    DameconResolver.swift
    BattleSessionReducer.swift
    BattleRankPredictor.swift
    BattleLogProjector.swift
  Quest/
    QuestModels.swift
    QuestDefinitionStore.swift
    QuestResetCalendar.swift
    QuestEvent.swift
    QuestEventRouter.swift
    QuestProgressReducer.swift
    QuestPresentationProjector.swift
  Persistence/
    P3SnapshotStore.swift

Packages/GameCore/Tests/GameCoreTests/P3/
  Fixtures/README.md
  Fixtures/Battle/*.json
  Fixtures/Quest/*.json
  BattlePhaseDecoderTests.swift
  DamageEngineTests.swift
  BattleSessionReducerTests.swift
  BattleRankPredictorTests.swift
  QuestResetCalendarTests.swift
  QuestProgressReducerTests.swift
  P3SnapshotStoreTests.swift

Game/P3/
  BattleStateModel.swift
  QuestStateModel.swift
  BattleQuestCoordinator.swift
Game/Battle/
  BattleOverlayView.swift
  BattleHeaderView.swift
  BattleFleetColumn.swift
  BattleShipRow.swift
  BattlePhaseTimelineView.swift
  BattleLogView.swift
Game/Quest/
  QuestOverlayView.swift
  QuestFilterBar.swift
  QuestRowView.swift
  QuestProgressDetailView.swift
Game/BundleAssets/P3/
  quest_track.json
  quests-jp.json
  quests-scn.json
  quests-tcn.json
  quests-en.json
  quests-ko.json
```

### 核心数据模型

```swift
struct BattleSnapshot: Codable, Sendable, Equatable {
    var sessionID: UUID
    var kind: BattleKind
    var map: BattleMapPosition?
    var formation: BattleFormation?
    var friendlyMain: BattleFleetState
    var friendlyEscort: BattleFleetState?
    var enemyMain: BattleFleetState
    var enemyEscort: BattleFleetState?
    var phases: [BattlePhaseResult]
    var escapedFriendly: Set<BattleShipPosition>
    var dameconActivations: [DameconActivation]
    var predictedRank: BattleRank?
    var serverRank: BattleRank?
    var status: BattleSessionStatus
    var warnings: [BattleParseWarning]
    var revision: Int64
}

struct BattleShipState: Codable, Sendable, Equatable, Identifiable {
    var id: BattleShipIdentity
    var position: BattleShipPosition
    var masterShipID: Int?
    var level: Int?
    var maximumHP: Int
    var initialHP: Int
    var currentHP: Int
    var escaped: Bool
    var damecon: DameconState
}

struct QuestProgressState: Codable, Sendable, Equatable {
    var questID: Int
    var state: QuestActivationState
    var category: QuestCategory
    var counters: [Int]
    var targets: [Int]
    var serverProgress: QuestServerProgress?
    var acceptedAt: Date?
    var resetAnchor: Date?
    var lastEventID: String?
}
```

所有索引统一转换为零基 `BattleShipPosition(fleet: .main/.escort, index: 0...5)`；原始 API 的 `-1`、前置 dummy `0` 和 6/12 偏移只能在 decoder 边界出现，不能泄漏到 UI。

---

## 5. Fixture 与金值规范

1. fixture 只能来自公开样例或开发者自己的脱敏响应；删除 `api_token`、member id、昵称、Cookie、Authorization、服务器 IP。
2. 战斗 fixture 保留原始 `api_data` 结构，文件名包含端点和形态，例如 `sortie_battle_single_day.json`、`combined_each_battle.json`、`sortie_midnight_continuation.json`。
3. 每份战斗 fixture 旁在 `README.md` 记录：初始 HP、阶段顺序、每阶段伤害、预期最终 HP、损管/退避、预期评级。
4. 金值必须由 Android `KcaBattle` 用同样 fixture 输出，或人工逐阶段计算并双人/脚本复核；禁止把 Swift 当前结果直接写成期望值。
5. 任务 fixture 将舰娘实例 id 重映射；任务定义 fixture 仅保留覆盖测试所需条目，不直接复制全部用户任务状态。
6. 日本时间测试必须固定 `Calendar(identifier: .gregorian)`、`TimeZone(identifier: "Asia/Tokyo")` 和 `now`，不得依赖运行机器时区。
7. 属性测试不引入第三方库；用确定性种子循环生成短数组、null、负值和越界索引，验证“永不崩溃、HP 不高于上限、同 event 幂等”。

敏感字段检查：

```bash
rg -n 'api_token|Cookie|Authorization|api_member_id|api_nickname|login_id|password' \
  /Users/haozhe/WorkTest/Game/Packages/GameCore/Tests/GameCoreTests/P3/Fixtures
```

---

## 6. 通用验证和阶段门禁

每个实现任务结束执行：

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme Game \
  -destination 'generic/platform=iOS Simulator' build

git diff --check
```

阶段门禁：

- **门禁 A（任务 1–4）：** 通常/联合战斗的基础阶段伤害全部通过；未通过不得开始战斗日志和 UI。
- **门禁 B（任务 5–7）：** 昼夜续战、损管、退避、评级通过；战斗核心方可视为完成。
- **门禁 C（任务 8–10）：** 任务列表、重置和进度 reducer 通过；未通过不得开始任务 UI。
- **门禁 D（任务 11–14）：** 持久化、App 接线、iPhone UI、iPad 适配和回归全部通过后完成 P3。

减少审查原则：任务 1–7 完成后做一次战斗核心集中审查；任务 8–10 完成后做一次任务核心集中审查；P3 验收前仅做一次集成审查。

---

## 任务 1：战斗端点、会话模型与初始 HP 解码

**目标：** 建立不依赖 UI 的战斗领域模型；正确初始化通常、我方联合、敌联合和演习战斗。

**文件：**

- 创建 `P3/Battle/BattleEndpoint.swift`
- 创建 `P3/Battle/BattleModels.swift`
- 创建 `P3/Battle/BattlePhase.swift`
- 创建 `P3/Battle/BattlePhaseDecoder.swift`
- 创建 `P3/BattleSessionInitializationTests.swift`
- 创建基础 battle fixtures 和 `Fixtures/README.md`

**实现：**

- `BattleEndpoint` 覆盖第 3.1 节端点，并标记 `initializesSession`、`continuesSession`、`isResult`、`isPractice`。
- 从 `api_f_maxhps/api_f_nowhps`、`api_e_maxhps/api_e_nowhps` 和 combined 变体构造四个可选舰队。
- 正确处理 dummy 首项、`-1` 空位、字符串 `"NaN"`、空/短数组；舰队最大 6 艘，超出只 warning。
- 敌舰 identity 使用 master id + 位置；我方 identity 从 P2 当前出击 deck 映射用户舰 id。
- map start 读取请求 `api_deck_id`，记录 map area/map/no、event id/kind、boss/end 标志。

**测试：** 单舰、6 艘、12 艘联合、敌联合、演习、缺 combined、空数组、异常长度。

**验证：**

```bash
swift test --filter BattleSessionInitializationTests
```

**提交：** `feat(p3): 战斗端点与会话模型`

---

## 任务 2：航空、支援和雷击阶段伤害解析

**目标：** 先完成最常见的向量伤害阶段，建立统一 `DamageEvent` 输出。

**文件：**

- 修改 `BattlePhaseDecoder.swift`
- 创建 `DamageEngine.swift`
- 创建 `BattleVectorPhaseTests.swift`
- fixtures：air base injection、air base attack、kouku、kouku2、support air/hourai、opening attack、raigeki。

**阶段与字段：**

1. `api_air_base_injection`
2. `api_injection_kouku`
3. `api_air_base_attack[]`
4. `api_kouku` / `api_kouku2`
5. `api_support_info.api_support_airatack.api_stage3.api_edam`
6. `api_support_info.api_support_hourai.api_damage`
7. `api_opening_atack.api_fdam/api_edam`
8. `api_raigeki.api_fdam/api_edam`

`api_stage3` 和 `api_stage3_combined` 分别映射主/护卫舰队；浮点伤害按 Android `cnv` 规则转换后再扣除。所有伤害通过 `DamageEngine.apply`，HP 最低可暂到 0，不允许负数继续累计。

**测试：** 双方伤害、combined 偏移、null stage、短数组、负伤害、浮点、重复应用 event ID 幂等。

**验证：** `swift test --filter BattleVectorPhaseTests`

**提交：** `feat(p3): 解析航空支援与雷击伤害阶段`

---

## 任务 3：炮击、先制反潜、友军与夜战伤害解析

**目标：** 解析 `api_df_list/api_damage/api_at_eflag` 攻击序列，并正确定位主/护卫、我/敌目标。

**文件：**

- 修改 `BattlePhaseDecoder.swift`、`DamageEngine.swift`
- 创建 `BattleShellingPhaseTests.swift`
- fixtures：opening taisen、hougeki1/2/3、night hougeki、friendly battle、enemy combined shelling。

**规则：**

- 支持每次攻击多个目标和多段伤害；`api_df_list[n][m]` 与 `api_damage[n][m]` 成对遍历。
- `api_at_eflag` 决定攻击方；`api_at_type` 或旧 `api_sp_list` 仅记录 attack kind，不改变伤害值。
- 覆盖 `api_opening_taisen`、`api_hougeki1...4`、夜战 `api_hougeki`、`api_friendly_battle.api_hougeki`。
- 将 Android 的 combined type/phase 分支收敛为显式 `BattleTargetLayout`，禁止散落 magic offset 6/12/20/100。
- 不合法目标只产生 warning；同一攻击中的其他合法目标继续应用。

**测试：** 单目标、多目标、同目标多 hit、我方攻击敌方、敌方攻击我方、敌联合、护卫舰队、旧字段、越界。

**验证：** `swift test --filter BattleShellingPhaseTests`

**提交：** `feat(p3): 解析炮击友军与夜战伤害阶段`

---

## 任务 4：战斗阶段排序与通常/联合会话 reducer

**目标：** 按 `KcaBattle.processData` 的端点特定顺序组合任务 2–3，不因 JSON key 顺序改变结果。

**文件：**

- 创建 `BattleSessionReducer.swift`
- 创建 `BattleSessionReducerTests.swift`
- fixtures：通常昼战、通常空袭、雷达射击、机动联合、水上联合、敌联合、联合对联合。

**实现要求：**

- 每个 endpoint 定义显式 phase plan；缺失阶段跳过，不重排存在阶段。
- 昼战初始化 `initialHP`，逐阶段追加 `BattlePhaseResult(before/after/events/warnings)`。
- 夜战 continuation 复用昼战 after HP；独立 `sp_midnight` 可从自身 HP 初始化。
- API 到达顺序非法时保留旧 session 并 warning；新 start/battle 可关闭旧 session 后启动新 session。
- `revision` 每个已应用响应只增加一次；重复 event ID 不增加。

**测试：** 使用完整 fixture 对比每阶段及最终 HP；同时覆盖缺失 kouku、null support、乱序 endpoint、重复响应。

**验证：**

```bash
swift test --filter BattleSessionReducerTests
swift test
```

**提交：** `feat(p3): 战斗阶段顺序与会话 reducer`

**门禁 A：** 任务 1–4 全量测试通过后，才能执行任务 12 的战斗 UI；任务 5–7 可继续完善纯逻辑。

---

## 任务 5：损管、女神、退避和大破判定

**目标：** 移植 `damecon_calculate`、escape list 和出击后大破判定。

**文件：**

- 创建 `DameconResolver.swift`
- 修改 `DamageEngine.swift`、`BattleSessionReducer.swift`
- 创建 `DameconResolverTests.swift`
- fixtures：普通损管、女神、无损管沉没、联合护卫损管、单/联合退避。

**规则：**

- 战斗初始化时从 P2 `FleetSnapshot` 的普通槽和增设槽快照损管状态；战斗中不反查可变 UI 状态。
- 舰娘 HP 首次降到 0 时：普通损管恢复 `floor(maxHP * 0.2)`，女神恢复 maxHP；记录 item id/舰位/阶段且标记 consumed。
- 同一舰同一场战斗不能二次触发；演习不消耗损管。
- goback_port 的 `api_escape_idx` / `api_escape_idx_combined` 转为位置集合；退避舰 UI 标记且排除返航大破警告。
- `retreatRisk` 区分 safe、heavyDamagedWithDamecon、heavyDamaged、sunk、unknown。

**测试：** 1 HP→沉没、同阶段多 hit、女神满血、损管 20%、重复响应、退避后 warning 清除、combined 映射。

**提交：** `feat(p3): 战斗损管退避与大破判定`

---

## 任务 6：战果评级预测与战斗结果合并

**目标：** 将 `calculateRank` / `calculateLdaRank` 转为纯函数，并在服务器结果到达时保留预测偏差诊断。

**文件：**

- 创建 `BattleRankPredictor.swift`
- 创建 `BattleRankPredictorTests.swift`
- fixtures：S/A/B/C/D/E、单舰大破、空袭战、联合舰队、敌 HP unknown。

**输入/输出：**

- 输入 initial/after HP、沉没数、舰数、战斗种类和是否练习。
- 输出 `BattleRankPrediction(rank, confidence, reasonCodes)`；未知 HP 时 confidence 降级，不强行给精确评级。
- result endpoint 合并 `api_win_rank`、MVP、combined MVP、经验、升级、掉落舰/道具；不得修改 P2 用户舰状态，等待后续 port/ship API authoritative 更新。
- 若预测与 server rank 不同，写入有限诊断和测试 fixture 候选，但不覆盖 server rank。

**测试：** 对照 Android 金值，覆盖除零、单舰、敌方全灭、我方沉没、空袭特殊评级。

**提交：** `feat(p3): 战果评级预测与结果合并`

---

## 任务 7：战斗事件摘要与受限日志投影

**目标：** 在核心正确后生成适合 UI/持久化的日志，不保存整份敏感原始响应。

**文件：**

- 创建 `BattleLogProjector.swift`
- 创建 `BattleLogProjectorTests.swift`

**模型：**

- `BattleLogEntry`: session id、时间、map/node、kind、敌舰队名、预测/实际 rank、最终 HP、退避/损管摘要。
- `BattlePhaseSummary`: phase kind、双方总伤害、沉没数、关键 warning。
- 最多保留最近 100 场，每场最多 32 phase summaries；字符串分别限制 128/512 字符。
- 不写 request body、token、完整 raw JSON、账号/member id。

**测试：** 容量淘汰、稳定排序、Codable round-trip、异常长文本截断、敏感字段不存在。

**提交：** `feat(p3): 战斗摘要与日志投影`

**门禁 B：** 战斗任务 1–7 全量测试通过并进行一次集中核心审查。

---

## 任务 8：任务定义、列表同步与日本时间重置

**目标：** 先建立服务端任务状态和本地精确计数的边界。

**文件：**

- 创建 `QuestModels.swift`
- 创建 `QuestDefinitionStore.swift`
- 创建 `QuestResetCalendar.swift`
- 创建 `QuestDefinitionStoreTests.swift`、`QuestResetCalendarTests.swift`
- 复制并注明来源的 quest track/translation assets 到 App bundle。

**规则：**

- 解析 `/api_get_member/questlist.api_list`，忽略 `-1` 占位；保存 id、category、type、state、server progress flag、title/detail。
- start 激活并创建 counters；stop 设 inactive 但保留未过期 counters；clear 删除并记录 completed。
- reset 使用 Asia/Tokyo 05:00：daily、Monday weekly、每月 1 日、3/6/9/12 月季度边界。
- 保留 Android 特例：211/212 非普通季度；311/318/330/337/339/342 按长日演习有效期；411/607/608 初值 1。
- 静态定义缺失时任务仍显示服务端标题和百分比，`precision = .serverOnly`。

**测试：** 04:59/05:00、跨日、周一、月末、季度、DST 无关性、系统时区非日本、start/stop/clear。

**提交：** `feat(p3): 任务定义列表同步与重置规则`

---

## 任务 9：任务事件路由和基础计数 reducer

**目标：** 将 API 转成稳定、可去重的语义事件，先覆盖不依赖复杂舰队条件的任务。

**文件：**

- 创建 `QuestEvent.swift`
- 创建 `QuestEventRouter.swift`
- 创建 `QuestProgressReducer.swift`
- 创建 `QuestBasicProgressTests.swift`
- fixtures：quest start/stop/clear、mission、nyukyo、charge、create/destroy item、create/destroy ship、remodel、powerup。

**事件：**

- `sortieStarted`、`nodeReached`、`battleFinished`
- `practiceFinished`、`expeditionStarted/Finished`
- `dockingStarted`、`supplied`
- `itemDeveloped/Discarded`、`shipBuilt/Acquired/Discarded`
- `equipmentImproved`、`modernizationCompleted`

**实现：**

- endpoint + request params + response 只在 router 边界解释；reducer 不依赖 URL 字符串。
- 对照 `KcaService` 的 `updateIdCountTracker` 建立显式 quest id/condition index 表。
- event ID LRU 与 Pipeline 共用；计数饱和到 target，仍可记录 server 超额但 UI 显示 100%。
- 未激活、已过期或定义不支持的任务不增加精确 counters。

**测试：** 每类事件、condition index、重复事件、未激活、过期、失败开发/建造、批量废弃数量。

**提交：** `feat(p3): 任务事件路由与基础进度 reducer`

---

## 任务 10：节点、战斗和编成条件任务进度

**目标：** 移植 `updateNodeTracker`、`updateQuestTracker`、`updateBattleTracker` 的地图、评级、敌舰种和编成条件。

**文件：**

- 修改 `QuestProgressReducer.swift`
- 创建 `QuestConditionEvaluator.swift`
- 创建 `QuestBattleProgressTests.swift`
- fixtures：boss/non-boss、S/A/B/C、carrier/AP/submarine sinks、指定 map、指定旗舰/舰种/舰娘组合、combined enemy。

**输入：**

- `BattleCompletedQuestEvent` 必须来自已经完成任务 4–6 的 `BattleSnapshot`，包含 world/map/node/boss/rank、敌舰 master/stype/final HP、出击舰 master/stype/位置。
- `NodeReachedQuestEvent` 来自 map start/next，包含 deck snapshot，不能在 reducer 中回读全局 mutable fleet。

**规则：**

- `S`、`A`、`B` 等级判断与 Android `isSRank/isGoodRank/isWinRank` 一致。
- 统计击沉航母、补给舰、潜艇时同时遍历敌主/护卫舰队，以 final HP <= 0 为准。
- 地图条件、boss 条件、多段 counters、指定旗舰/舰种/舰娘 id 用数据驱动 predicate 表；复杂遗留任务允许专用 evaluator，但必须有 quest id 命名测试。
- 第一批覆盖 Android tracker 当前所有 switch case；不认识的新任务只保留 server progress。
- `ap_dup_flag` 的 212/218 逻辑建模为显式 session flag，禁止全局 static。

**测试：** Android switch 中每个分支至少一个正例；共享规则有负例；联合敌舰统计和非 boss 不误计数。

**提交：** `feat(p3): 节点战果与编成任务进度`

**门禁 C：** 任务 8–10 全量测试通过并进行一次任务核心集中审查；之后才能接任务 UI。

---

## 任务 11：P3 SQLite 持久化和恢复

**目标：** 原子保存任务进度、最近战斗和 schema 版本，不扩大 P2 数据库耦合。

**文件：**

- 创建 `P3/Persistence/P3SnapshotStore.swift`
- 创建 `P3SnapshotStoreTests.swift`

**schema v1：**

- `p3_meta(key, value)`：schema、battle revision、quest revision。
- `quest_progress(quest_id PRIMARY KEY, payload BLOB, updated_at)`。
- `battle_log(session_id PRIMARY KEY, started_at, payload BLOB)`。
- `battle_current(id=1, payload BLOB, status, updated_at)`。

**要求：**

- SQLite3、WAL、busy timeout、单事务；typed error 与 P2 `GameSnapshotStore` 风格一致。
- revision 防倒退；损坏单条 payload 隔离并报告，不让整个数据库不可用。
- 启动恢复进行中 battle 时改为 `.restoredIncomplete`；下一场开始时归档或替换。
- 日志最多 100 场；任务 completed 可保留 7 天后清理，active 不清理。
- App Group 路径复用 `SharedContainer`，但不得修改 Widget schema。

**测试：** round-trip、事务回滚、并发 save、revision 倒退、损坏 payload、版本过高、容量淘汰。

**提交：** `feat(p3): 战斗任务 SQLite 持久化`

---

## 任务 12：Pipeline/App 接线与可观察状态

**目标：** 将 P3 reducer 接入现有 JSBridge 和悬浮球导航；不破坏 P2 reducer。

**文件：**

- 修改 `P2/Pipeline/GameDataPipeline.swift`（单代理串行修改）
- 修改 `Game/P2/GameDataCoordinator.swift` 或创建 `Game/P3/BattleQuestCoordinator.swift`
- 修改 `Game/P2/GameStateModel.swift` 或创建两个 P3 model
- 修改 `RootView.swift`、`GameView.swift` 的 destination presentation
- 创建 `BattleQuestIntegrationTests.swift`

**接线顺序：**

1. envelope 解析一次。
2. P2 fleet reducer 先提交 authoritative 舰队变化。
3. 战斗 endpoint 用“事件到达前或地图 start 时”的出击 deck snapshot 初始化 session。
4. 生成 battle result 后投递 semantic quest event。
5. quest reducer 提交后统一持久化 P3 snapshot。
6. `@MainActor` 一次 publish battle/quest view state，避免半更新 UI。

**要求：**

- 共享 `eventID` 幂等，防止战斗扣血和任务计数各自重复。
- `JSBridge` 消息尺寸/来源校验继续沿用 P1，不放宽安全边界。
- P3 失败只调用 `DiagnosticsStore` 和 model error；P2 state 仍可更新。
- destination `.battle/.quest` 打开原生 sheet/overlay，不新建 WebView，不 reload 页面。

**测试：** replay 一段 map start→battle→night→result→port；验证 battle HP、quest counter、P2 fleet revision、恢复后幂等。

**提交：** `feat(p3): 接入战斗与任务数据管线`

---

## 任务 13：iPhone 横屏战斗覆盖页与战斗日志

**目标：** 在不遮挡主要游戏交互的前提下提供实时 HP、评级和返航风险。

**文件：**

- 创建 `Game/Battle/BattleOverlayView.swift`
- 创建 `BattleHeaderView.swift`、`BattleFleetColumn.swift`、`BattleShipRow.swift`
- 创建 `BattlePhaseTimelineView.swift`、`BattleLogView.swift`
- 修改 `FloatingMenuView.swift`/destination host 仅做接线。

**iPhone 横屏布局：**

- 默认覆盖屏幕宽度不超过可用宽度 88%，高度不超过 82%；背景 material + 高对比描边。
- 顶栏：海域/节点、阵型、阶段、预测/实际评级、关闭按钮。
- 中部双列：左我方主/护卫，右敌方主/护卫；紧凑行显示舰名、HP 数字、HP 条、状态图标。
- 大破/沉没/损管/退避必须同时使用颜色、SF Symbol 和文字，不能只靠颜色。
- 默认不展示装备详情；点击舰行显示 popover，减少常驻内存和遮挡。
- 底部可折叠 phase timeline；日志作为二级 tab，不与实时战斗同屏抢空间。
- VoiceOver label 包含阵营、舰位、舰名、HP、状态；Dynamic Type 到 `.accessibility2` 仍可滚动。

**iPad：** Regular width 使用 2/3 实时战斗 + 1/3 timeline/log 分栏；不单独发明功能。

**性能：** 使用值类型 row model 和稳定 id；phase 历史只显示摘要；禁止在 body 解析 JSON；一次 API 更新不得创建第二个 WKWebView。

**验证：** iPhone SE 等宽横屏、主流 6.1/6.7 英寸、iPad 11/13；空状态、通常 6 艘、联合 12+12、超长舰名、大破多行。

**提交：** `feat(p3): iPhone 横屏战斗覆盖页`

---

## 任务 14：iPhone 横屏任务覆盖页、筛选和详情

**目标：** 从悬浮球“任务”打开原生任务列表，优先显示已接和可精确追踪任务。

**文件：**

- 创建 `Game/Quest/QuestOverlayView.swift`
- 创建 `QuestFilterBar.swift`、`QuestRowView.swift`、`QuestProgressDetailView.swift`
- 接入 destination host 和本地化 assets。

**布局与交互：**

- iPhone 横屏使用单列表 + 顶部横向 filter：已接、可追踪、已完成、全部；默认已接。
- 每行显示类型、id、标题、服务端百分比、精确 counter/target、重置时间；精度不足明确显示“服务器估算”。
- 多条件任务显示总进度和展开详情；不能把 `[1,0,1,0]` 错显示为简单 50%，应列出各条件。
- tab/category 和 filter 只在本地切换，不触发游戏 API 请求。
- 空列表、静态定义缺失、恢复数据 stale、重置刚发生均有明确状态文案。
- iPad Regular 使用左侧筛选/任务列表、右侧详情分栏。

**验证：** 5/20/100 项、超长中文/日文、未知定义、多 counters、完成状态、VoiceOver、Dynamic Type。

**提交：** `feat(p3): iPhone 横屏任务追踪覆盖页`

---

## 任务 15：设置、诊断与功能开关

**目标：** 给高成本功能提供用户可控开关，并让错误可诊断但不泄露数据。

**文件：**

- 修改 `SettingsStore.swift`、`SettingsView.swift`
- 修改 `DiagnosticsStore.swift`
- 创建 `P3SettingsTests.swift`

**设置：**

- 战斗覆盖自动刷新（默认开）。
- 显示敌方装备详情（默认关）。
- 保留战斗日志数量 20/50/100（默认 50）。
- 任务精确追踪（默认开）。
- 任务完成提示（默认开，仅 App 内 banner；本阶段不增加本地通知配额）。
- 调试：显示最近 endpoint、battle/quest revision、warning 次数、预测/实际评级偏差次数、数据库大小。

**隐私：** 导出诊断只含端点 path、错误类型和受限摘要；不含原始响应、请求 body、token、昵称、member id。

**提交：** `feat(p3): 战斗任务设置与诊断`

---

## 任务 16：P3 验收、回归和交付记录

**目标：** 用自动化 replay 和设备验收确认 P1/P2/P3 可共同工作。

**文件：**

- 创建 `docs/superpowers/p3-acceptance.md`
- 必要时增加脱敏 replay fixtures；不得以验收名义修改核心算法。

### 自动化验收

```bash
cd /Users/haozhe/WorkTest/Game/Packages/GameCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

cd /Users/haozhe/WorkTest/Game
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Game.xcodeproj -scheme Game \
  -destination 'generic/platform=iOS Simulator' build

git diff --check
```

必须记录：测试总数、失败数、build 结果、fixture 敏感字段扫描结果。

### iPhone 实机验收（必须先通过）

1. 登录并进入游戏后锁定横屏，页面只显示游戏画布和悬浮球。
2. 通常昼战：每个阶段后 HP 与游戏结果一致。
3. 昼转夜：夜战从昼战结束 HP 继续，不重置。
4. 联合舰队：主/护卫索引和敌联合伤害正确。
5. 损管/女神：UI 显示发动一次；退避后不误报返航风险。
6. 战果：预测评级更新，result 到达后显示服务器评级、MVP/经验/掉落摘要。
7. 任务：接受/停止/领取后列表同步；完成一次可验证事件后精确 counter +1 且不重复。
8. WebContent 进程终止并恢复后，P3 不重复应用最后响应；浏览器白屏恢复仍有效。
9. 连续 5 场战斗后观察内存，无持续无界增长；打开/关闭覆盖页不创建额外 WebView。

### iPad 验收（iPhone 通过后）

- Split View 和全屏下战斗/任务分栏无裁切。
- 悬浮球、关闭按钮、列表滚动和游戏触控区域均可用。
- 旋转/窗口尺寸变化后状态不丢失，不重复解析 API。

### 失败准则

以下任一情况必须阻止 P3 完成：

- 任一阶段重复扣血、主/护卫索引错位或夜战错误重置 HP。
- 损管重复触发、退避舰仍触发大破返航警告。
- 任务重复计数、跨日本时间重置后保留旧进度、未知任务伪造精确计数。
- 打开覆盖页引发 WebView reload、明显白屏或新增常驻 WebView。
- fixture 或日志包含 token、账号、昵称、member id。
- P1/P2 回归测试失败。

**提交：** `docs: P3 验收记录`

---

## 7. 推荐执行顺序与并行边界

### 第一波：战斗伤害核心（最优先）

- 任务 1 先单独完成模型和初始化。
- 任务 2 与任务 3 可并行，但只各自创建 phase decoder extension/测试；最终由任务 4 单代理合并共享 `BattlePhaseDecoder.swift`。
- 任务 4 串行完成并通过门禁 A。

### 第二波：战斗完整性与任务基础

门禁 A 后可分两条并行轨道：

- 战斗轨：任务 5（损管/退避）与任务 6（评级）并行，任务 7 在两者后执行。
- 任务轨：任务 8（定义/重置）先完成；任务 9（基础事件）随后开始。

任务 7 后做一次战斗核心集中审查，不逐提交反复审查。

### 第三波：任务复杂条件与持久化

- 任务 10 依赖任务 8–9，并依赖任务 4–6 产出的 battle semantic event。
- 任务 11 可在任务 7 和任务 8 模型稳定后并行开发，但 schema 合并由单代理完成。
- 任务 10 后做一次任务核心集中审查。

### 第四波：App 接线与 UI

- 任务 12 必须由单代理修改 Pipeline/Coordinator/RootView 共享文件。
- 任务 13 和任务 14 在任务 12 提供稳定 model 后可并行，文件目录互不重叠。
- 任务 15 可与 UI 后半段并行，但 `SettingsView.swift` 只允许一个代理修改。
- 任务 16 最后执行，做一次集成审查和完整验收。

### 子代理文件所有权建议

| 代理 | 独占目录/文件 | 禁止修改 |
|---|---|---|
| Battle Core A | `P3/Battle/BattleModels*`、初始化 tests | Pipeline、App UI |
| Battle Core B | vector phase 独立文件/tests | Quest、App UI |
| Battle Core C | shelling phase 独立文件/tests | Quest、App UI |
| Quest Core | `P3/Quest/*`、Quest tests | Battle、App UI |
| Persistence | `P3/Persistence/*` | P2 Widget schema |
| Integration | Pipeline、Coordinator、RootView | 算法金值 |
| Battle UI | `Game/Battle/*` | Quest UI、Core reducer |
| Quest UI | `Game/Quest/*` | Battle UI、Core reducer |

共享文件冲突时，不允许代理通过 `git checkout --`、reset 或覆盖他人未提交内容解决；应暂停并由主代理串行合并。

---

## 8. 主要风险与预案

1. **游戏 API 变体多：** 使用 endpoint phase plan + tolerant decoder；未知字段 warning，不让整个 session 失败。
2. **联合舰队索引易错：** 只允许 `BattleShipPosition` 参与 Core；magic offset 仅存在于有 fixture 的 decoder。
3. **Android 静态全局状态难移植：** Swift 用 actor 内值类型 session，严禁全局 static mutable battle/quest 状态。
4. **任务规则硬编码量大：** 通用规则数据驱动，特殊 quest evaluator 按 id 命名并逐项测试；未知任务退化为 server-only。
5. **日本时间重置：** 所有 reset 计算注入 Calendar/now；不使用设备本地午夜。
6. **日志导致内存/磁盘增长：** 仅存摘要、严格容量和字符串上限，原始 API 不落库。
7. **UI 遮挡游戏：** iPhone 默认紧凑 overlay，可一键关闭；详情按需展示，悬浮球保持最高交互优先级。
8. **WebView 内存压力：** P3 UI 不创建 WebView、不缓存舰船大图、不保存大 JSON；系统内存告警时可丢弃 phase 展示缓存但保留当前 snapshot。
9. **重复桥消息：** event ID 在 Pipeline 统一去重；Core reducer 仍提供幂等测试作为第二道防线。
10. **P2 同时开发冲突：** P3 开始接线前先确保 P2 Widget/通知等工作树干净；算法目录可提前并行，Pipeline/RootView 必须等共享文件稳定。

---

## 9. P3 最终产物清单

- 战斗端点和 session 状态机。
- 航空、基地、支援、反潜、雷击、炮击、友军、夜战阶段解析。
- 通常/联合/敌联合舰队 HP 演算。
- 损管、女神、退避、大破返航风险。
- 评级预测和服务器战果合并。
- 任务列表同步、日本时间重置和精确进度 reducer。
- 战斗/任务 SQLite 持久化和受限日志。
- iPhone 横屏战斗覆盖页、任务覆盖页和悬浮球接线。
- iPad 自适应分栏。
- 设置、诊断、fixtures、Core 测试和 P3 验收记录。

完成这些产物并通过任务 16 后，才进入 P4 掉落/资源日志、图鉴、改修工厂和高级工具。
