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
        case gauges = "海域/陆航"
        var id: Self { self }
    }

    let gameState: GameDataState
    let timers: [GameTimer]
    @State private var tab: Tab = .timers

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
                ExpeditionTableView(fleet: gameState.fleet, master: gameState.master)
            case .gauges:
                SortieSupportView(gauges: gameState.mapGauges, bases: gameState.landAirBases)
            }
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
                    name: master.ships[selected.masterShipID]?.name ?? "舰船 #\(selected.masterShipID)"
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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name).font(.title3.bold())
            LabeledContent("等级", value: "Lv.\(ship.level)")
            LabeledContent("耐久", value: "\(ship.currentHP) / \(ship.maximumHP)")
            LabeledContent("士气", value: "\(ship.condition)")
            LabeledContent("燃料", value: "\(ship.fuel)")
            LabeledContent("弹药", value: "\(ship.ammunition)")
            LabeledContent("装备槽", value: "\(ship.slotItemIDs.count)")
            Spacer()
        }
        .padding()
    }
}

private struct EquipmentLibraryView: View {
    let fleet: FleetSnapshot
    let master: GameMasterData
    @State private var query = ""

    private var items: [UserSlotItem] {
        fleet.slotItems.values.filter {
            query.isEmpty || (master.slotItems[$0.masterSlotItemID]?.name ?? "").localizedCaseInsensitiveContains(query)
        }.sorted { ($0.masterSlotItemID, $0.id) < ($1.masterSlotItemID, $1.id) }
    }

    var body: some View {
        List(items, id: \.id) { item in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(master.slotItems[item.masterSlotItemID]?.name ?? "装备 #\(item.masterSlotItemID)")
                    Text("改修 +\(item.improvementLevel) · 熟练 \(item.aircraftProficiency)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.locked { Image(systemName: "lock.fill").foregroundStyle(.yellow) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "搜索装备")
        .overlay {
            if items.isEmpty { ContentUnavailableView("暂无装备", systemImage: "shippingbox") }
        }
    }
}
