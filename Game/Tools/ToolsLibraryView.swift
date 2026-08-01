import SwiftUI
import GameCore

/// Native P2 tools backed by the same immutable game snapshot as the fleet HUD.
/// They never touch WebKit or SQLite directly, so opening a tool cannot disrupt play.
struct ToolsLibraryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case timers = "计时"
        case ships = "舰娘"
        case equipment = "装备"
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
            }
        }
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
