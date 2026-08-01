import SwiftUI
import GameCore

/// Native P2 tools backed by the same immutable game snapshot as the fleet HUD.
/// They never touch WebKit or SQLite directly, so opening a tool cannot disrupt play.
struct ToolsLibraryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case timers = "计时"
        case ships = "舰娘"
        case equipment = "装备"
        case expeditions = "远征"
        case improvement = "明石"
        case experience = "经验"
        case gauges = "海域/陆航"
        var id: Self { self }
    }

    let gameState: GameDataState
    let timers: [GameTimer]
    @State private var tab: Tab = .timers
    @StateObject private var staticData = ToolStaticData()

    var body: some View {
        VStack(spacing: 10) {
            Picker("工具", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch tab {
            case .timers:
                TimerOverlayView(timers: timers)
            case .ships:
                ShipLibraryView(fleet: gameState.fleet, master: gameState.master)
            case .equipment:
                EquipmentLibraryView(fleet: gameState.fleet, master: gameState.master)
            case .expeditions:
                ExpeditionTableView(fleet: gameState.fleet, master: gameState.master, details: staticData.expeditions)
            case .improvement:
                AkashiImprovementView(fleet: gameState.fleet, master: gameState.master, entries: staticData.akashi)
            case .experience:
                ExperienceCalculatorView(levelTable: staticData.levelTable, mapExperience: staticData.expeditions)
            case .gauges:
                SortieSupportView(gauges: gameState.mapGauges, bases: gameState.landAirBases)
            }

            ToolDataStatusView(data: staticData)
        }
    }
}

private struct SortieSupportView: View {
    let gauges: [MapGaugeState]
    let bases: [LandAirBaseState]
    var body: some View {
        List {
            Section("海域血条") {
                if gauges.isEmpty { Text("暂无未完成海域血条").foregroundStyle(.secondary) }
                ForEach(gauges) { gauge in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text("\(gauge.mapAreaID)-\(gauge.mapNumber) \(gauge.isTransport ? "TP" : "HP")\(gauge.gaugeNumber > 0 ? " #\(gauge.gaugeNumber)" : "")"); Spacer(); Text("\(gauge.current)/\(gauge.maximum)").monospacedDigit() }
                        ProgressView(value: Double(gauge.current), total: Double(gauge.maximum)).tint(gauge.isTransport ? .cyan : .green)
                    }
                }
            }
            Section("基地航空队") {
                if bases.isEmpty { Text("暂无基地航空队数据").foregroundStyle(.secondary) }
                ForEach(bases) { base in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("[\(base.areaID)-\(base.id)] \(base.name)"); Spacer(); Text(status(base.actionKind)).foregroundStyle(.cyan) }
                        Text("航程 \(base.distance) · 槽位 \(base.planes.filter { $0.state > 0 }.count)/\(base.planes.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    private func status(_ value: Int) -> String { switch value { case 1: "待机"; case 2: "出击"; case 3: "防空"; case 4: "退避"; case 5: "休息"; default: "未知" } }
}

private struct ExpeditionTableView: View {
    let fleet: FleetSnapshot
    let master: GameMasterData
    let details: [ToolStaticData.Expedition]
    @State private var query = ""

    private var missions: [MasterMission] {
        master.missions.values.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || "\($0.id)".contains(query)
        }.sorted { $0.id < $1.id }
    }

    var body: some View {
        List(missions, id: \.id) { mission in
            HStack(spacing: 10) {
                Image(systemName: activeDeck(for: mission.id) == nil ? "ferry" : "ferry.fill")
                    .foregroundStyle(activeDeck(for: mission.id) == nil ? Color.secondary : Color.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(mission.id). \(mission.name.isEmpty ? "远征 #\(mission.id)" : mission.name)")
                    Text(durationText(mission.durationMinutes))
                        .font(.caption).foregroundStyle(.secondary)
                    if let detail = details.first(where: { Int($0.no) == mission.id }) {
                        Text(expeditionDetail(detail)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let deck = activeDeck(for: mission.id), let completion = deck.expedition?.completionTime {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(deck.name.isEmpty ? "第\(deck.id)舰队" : deck.name).font(.caption)
                        Text(Date(timeIntervalSince1970: TimeInterval(completion) / 1_000), style: .timer)
                            .font(.caption.monospacedDigit()).foregroundStyle(.cyan)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "搜索远征名称或编号")
        .overlay {
            if missions.isEmpty {
                ContentUnavailableView(
                    "暂无远征数据",
                    systemImage: "ferry",
                    description: Text("进入母港后刷新游戏，以接收远征一览。")
                )
            }
        }
    }

    private func activeDeck(for missionID: Int) -> FleetDeck? {
        fleet.decks.values.first { $0.expedition?.isActive == true && $0.expedition?.missionID == missionID }
    }

    private func durationText(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "时长未知" }
        return minutes >= 60 ? "时长 \(minutes / 60)小时\(minutes % 60)分" : "时长 \(minutes)分"
    }

    private func expeditionDetail(_ value: ToolStaticData.Expedition) -> String {
        let resources = (value.resource ?? []).prefix(4).map(String.init).joined(separator: "/")
        let condition = [value.totalNum.map { "\($0)舰" }, value.flagLevel.map { "旗舰Lv.\($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return "资源 \(resources.isEmpty ? "—" : resources)\(condition.isEmpty ? "" : " · \(condition)")"
    }
}

private struct ToolDataStatusView: View {
    @ObservedObject var data: ToolStaticData
    var body: some View {
        HStack(spacing: 8) {
            if data.levelTable.isEmpty || data.expeditions.isEmpty || data.akashi.isEmpty {
                Text("完整工具资料未下载").font(.caption).foregroundStyle(.secondary)
            } else if let updated = data.lastUpdated {
                Text("资料更新于 \(updated, format: .dateTime.year().month().day())").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(data.isUpdating ? "更新中…" : "更新资料") { Task { await data.update() } }
                .font(.caption).disabled(data.isUpdating)
        }
        .padding(.horizontal, 4)
        .alert("工具资料", isPresented: Binding(get: { data.errorMessage != nil }, set: { if !$0 { data.dismissError() } })) {
            Button("好", role: .cancel) { data.dismissError() }
        } message: { Text(data.errorMessage ?? "") }
    }
}

private struct ShipLibraryView: View {
    let fleet: FleetSnapshot
    let master: GameMasterData
    @State private var query = ""
    @State private var sortByLevel = true
    @State private var selected: UserShip?

    private var ships: [UserShip] {
        fleet.ships.values
            .filter { ship in
                query.isEmpty || (master.ships[ship.masterShipID]?.name ?? "").localizedCaseInsensitiveContains(query)
            }
            .sorted {
                if sortByLevel, $0.level != $1.level { return $0.level > $1.level }
                return $0.id < $1.id
            }
    }

    var body: some View {
        List(ships, id: \.id) { ship in
            Button { selected = ship } label: {
                HStack(spacing: 9) {
                    Circle().fill(hpColor(ship)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(master.ships[ship.masterShipID]?.name ?? "舰船 #\(ship.masterShipID)")
                            .foregroundStyle(.primary)
                        Text("Lv.\(ship.level) · Cond \(ship.condition) · HP \(ship.currentHP)/\(ship.maximumHP)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ship.locked { Image(systemName: "lock.fill").foregroundStyle(.yellow) }
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "搜索舰娘")
        .toolbar {
            Button(sortByLevel ? "等级排序" : "ID 排序") { sortByLevel.toggle() }
        }
        .overlay {
            if ships.isEmpty { ContentUnavailableView("暂无舰娘", systemImage: "ship") }
        }
        .sheet(isPresented: Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil } }
        )) {
            if let selected {
                ShipDetailView(
                    ship: selected,
                    name: master.ships[selected.masterShipID]?.name ?? "舰船 #\(selected.masterShipID)",
                    shipType: master.shipTypes[master.ships[selected.masterShipID]?.shipTypeID ?? 0]?.name,
                    masterShip: master.ships[selected.masterShipID],
                    items: selected.slotItemIDs.compactMap { fleet.slotItems[$0] },
                    masterItems: master.slotItems
                )
                .presentationDetents([.medium])
            }
        }
    }

    private func hpColor(_ ship: UserShip) -> Color {
        guard ship.maximumHP > 0 else { return .secondary }
        return ship.currentHP * 4 <= ship.maximumHP ? .red : ship.currentHP * 2 <= ship.maximumHP ? .orange : .green
    }
}

private struct ShipDetailView: View {
    let ship: UserShip
    let name: String
    let shipType: String?
    let masterShip: MasterShip?
    let items: [UserSlotItem]
    let masterItems: [Int: MasterSlotItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name).font(.title3.bold())
            if let shipType, !shipType.isEmpty { Text(shipType).foregroundStyle(.secondary) }
            LabeledContent("等级", value: "Lv.\(ship.level)")
            LabeledContent("耐久", value: "\(ship.currentHP) / \(ship.maximumHP)")
            LabeledContent("士气", value: "\(ship.condition)")
            LabeledContent("燃料", value: "\(ship.fuel)")
            LabeledContent("弹药", value: "\(ship.ammunition)")
            if let masterShip {
                Divider()
                Text("基础属性").font(.headline)
                statRows(masterShip)
            }
            Divider()
            Text("装备").font(.headline)
            if items.isEmpty { Text("未装备").foregroundStyle(.secondary) }
            ForEach(items, id: \.id) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(masterItems[item.masterSlotItemID]?.name ?? "装备 #\(item.masterSlotItemID)"); Spacer(); Text("+\(item.improvementLevel)").monospacedDigit().foregroundStyle(.secondary) }
                    if let item = masterItems[item.masterSlotItemID] {
                        Text(equipmentStatText(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder private func statRows(_ ship: MasterShip) -> some View {
        let values: [(String, [Int]?)] = [
            ("火力", ship.firepower), ("雷装", ship.torpedo), ("对空", ship.antiAir),
            ("装甲", ship.armor), ("对潜", ship.antiSubmarine), ("索敌", ship.search), ("运", ship.luck)
        ]
        ForEach(values.filter { !($0.1 ?? []).isEmpty }, id: \.0) { title, value in
            LabeledContent(title, value: rangeText(value ?? []))
        }
    }

    private func rangeText(_ value: [Int]) -> String {
        value.count > 1 ? "\(value[0]) → \(value[1])" : "\(value.first ?? 0)"
    }

    private func equipmentStatText(_ item: MasterSlotItem) -> String {
        let values = [
            ("火", item.firepower), ("雷", item.torpedo), ("爆", item.bombing), ("空", item.antiAir),
            ("潜", item.antiSubmarine), ("索", item.search), ("命", item.accuracy), ("回", item.evasion)
        ].compactMap { label, value in value.map { "\(label)+\($0)" } }
        return values.isEmpty ? "无战斗属性数据" : values.joined(separator: " · ")
    }
}

private struct EquipmentLibraryView: View {
    let fleet: FleetSnapshot
    let master: GameMasterData
    @State private var query = ""
    @State private var category = 0

    private var items: [UserSlotItem] {
        fleet.slotItems.values.filter {
            let itemCategory = master.slotItems[$0.masterSlotItemID]?.category ?? 0
            return (category == 0 || itemCategory == category)
                && (query.isEmpty || (master.slotItems[$0.masterSlotItemID]?.name ?? "").localizedCaseInsensitiveContains(query))
        }.sorted { ($0.masterSlotItemID, $0.id) < ($1.masterSlotItemID, $1.id) }
    }

    var body: some View {
        List(items, id: \.id) { item in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(master.slotItems[item.masterSlotItemID]?.name ?? "装备 #\(item.masterSlotItemID)")
                    Text(equipmentSubtitle(item))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.locked { Image(systemName: "lock.fill").foregroundStyle(.yellow) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "搜索装备")
        .safeAreaInset(edge: .top) {
            Picker("装备类型", selection: $category) {
                Text("全部类型").tag(0)
                ForEach(categories, id: \.self) { Text("类型 \($0)").tag($0) }
            }.pickerStyle(.menu).padding(.horizontal)
        }
        .overlay {
            if items.isEmpty { ContentUnavailableView("暂无装备", systemImage: "shippingbox") }
        }
    }

    private var categories: [Int] { Array(Set(fleet.slotItems.values.compactMap { master.slotItems[$0.masterSlotItemID]?.category })).sorted() }

    private func equipmentSubtitle(_ item: UserSlotItem) -> String {
        let masterItem = master.slotItems[item.masterSlotItemID]
        let stats = [("火", masterItem?.firepower), ("雷", masterItem?.torpedo), ("爆", masterItem?.bombing), ("空", masterItem?.antiAir), ("潜", masterItem?.antiSubmarine), ("索", masterItem?.search)]
            .compactMap { label, value in value.map { "\(label)+\($0)" } }
            .joined(separator: " ")
        return "类型 \(masterItem?.category ?? 0) · 改修 +\(item.improvementLevel) · 熟练 \(item.aircraftProficiency)\(stats.isEmpty ? "" : " · \(stats)")"
    }
}

private struct AkashiImprovementView: View {
    let fleet: FleetSnapshot
    let master: GameMasterData
    let entries: [Int: ToolStaticData.AkashiEntry]
    @State private var onlyOwned = true
    @State private var selectedID: Int?

    private var ids: [Int] {
        let owned = Set(fleet.slotItems.values.map(\.masterSlotItemID))
        return entries.keys.filter { !onlyOwned || owned.contains($0) }.sorted { (master.slotItems[$0]?.name ?? "") < (master.slotItems[$1]?.name ?? "") }
    }

    var body: some View {
        List(ids, id: \.self) { id in
            Button { selectedID = id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(master.slotItems[id]?.name ?? "装备 #\(id)").foregroundStyle(.primary)
                    Text("\(entries[id]?.improvements.count ?? 0) 条改修方案").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top) { Toggle("仅显示已持有装备", isOn: $onlyOwned).font(.caption).padding(.horizontal) }
        .overlay {
            if entries.isEmpty { ContentUnavailableView("暂无改修资料", systemImage: "wrench.and.screwdriver", description: Text("在工具底部点击“更新资料”下载公开的改修数据库。")) }
            else if ids.isEmpty { ContentUnavailableView("没有符合的装备", systemImage: "shippingbox") }
        }
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let selectedID = selectedID, let entry = entries[selectedID] {
                AkashiDetailView(entry: entry, itemName: master.slotItems[selectedID]?.name ?? "装备 #\(selectedID)", master: master)
            }
        }
    }
}

private struct AkashiDetailView: View {
    let entry: ToolStaticData.AkashiEntry
    let itemName: String
    let master: GameMasterData
    var body: some View {
        NavigationStack {
            List {
                Section("改修方案") {
                    ForEach(Array(entry.improvements.enumerated()), id: \.offset) { index, rule in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(rule.upgradeItemID.map { "改修后：\(master.slotItems[$0]?.name ?? "装备 #\($0)")\(rule.upgradeLevel.map { " +\($0)" } ?? "")" } ?? "等级改修")
                            Text("可改修日：\(weekdayText(rule.days))").font(.caption).foregroundStyle(.secondary)
                            if !rule.secretaryShipIDs.isEmpty {
                                Text("秘书舰：\(rule.secretaryShipIDs.map { master.ships[$0]?.name ?? "#\($0)" }.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary)
                            }
                            if !rule.resources.isEmpty { Text("资源：\(rule.resources.map(String.init).joined(separator: " / "))").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 2)
                    }
                }
                if !entry.defaultEquippedOn.isEmpty {
                    Section("初始装备舰娘") { Text(entry.defaultEquippedOn.map { master.ships[$0]?.name ?? "#\($0)" }.joined(separator: "、")) }
                }
            }
            .navigationTitle(itemName).navigationBarTitleDisplayMode(.inline)
        }
    }
    private func weekdayText(_ days: Set<Int>) -> String {
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        return days.isEmpty ? "资料未标注" : days.sorted().map { labels.indices.contains($0) ? labels[$0] : "?" }.joined(separator: "、")
    }
}

private struct ExperienceCalculatorView: View {
    let levelTable: [Int: (next: Int, total: Int)]
    let mapExperience: [ToolStaticData.Expedition]
    @State private var level = 1
    @State private var currentExperience = "0"
    @State private var gain = "100"

    private var total: Int { Int(currentExperience) ?? 0 }
    private var gained: Int { max(0, Int(gain) ?? 0) }
    private var currentThreshold: Int { levelTable[level]?.total ?? 0 }
    private var nextThreshold: Int { levelTable[level + 1]?.total ?? (currentThreshold + (levelTable[level]?.next ?? 0)) }
    private var progress: Double { guard nextThreshold > currentThreshold else { return 1 }; return min(1, max(0, Double(total - currentThreshold) / Double(nextThreshold - currentThreshold))) }
    private var resultingLevel: Int { levelTable.keys.sorted().last(where: { (levelTable[$0]?.total ?? 0) <= total + gained }) ?? level }

    var body: some View {
        Form {
            Section("舰娘等级经验") {
                Stepper("当前等级 Lv.\(level)", value: $level, in: 1...188)
                TextField("当前累计经验", text: $currentExperience).keyboardType(.numberPad)
                if !levelTable.isEmpty {
                    VStack(alignment: .leading) { ProgressView(value: progress); Text("本级 \(max(0, total - currentThreshold)) / \(max(0, nextThreshold - currentThreshold))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("单次经验") {
                TextField("本次获得经验", text: $gain).keyboardType(.numberPad)
                Text("预计 Lv.\(resultingLevel) · 累计 \(total + gained) EXP").foregroundStyle(.cyan)
            }
            Section("远征经验参考") {
                if mapExperience.isEmpty { Text("更新工具资料后显示远征经验。 ").foregroundStyle(.secondary) }
                ForEach(mapExperience.prefix(12)) { item in
                    Text("\(item.displayName)：提督 \(item.exp?.first ?? 0) / 舰娘 \(item.exp?.dropFirst().first ?? 0)").font(.caption)
                }
            }
        }
    }
}
