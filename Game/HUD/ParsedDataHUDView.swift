import SwiftUI
import GameCore

/// Kcanotify-style compact native overlay shown above the single game WebView.
/// It consumes already-reduced value models and never parses JSON or creates
/// another browser process.
struct ParsedDataHUDView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case fleet = "舰队"
        case battle = "战斗"
        case quest = "任务"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .fleet: "person.3.fill"
            case .battle: "scope"
            case .quest: "checklist"
            }
        }

        var destination: GameMenuDestination {
            switch self {
            case .fleet: .fleet
            case .battle: .battle
            case .quest: .quest
            }
        }
    }

    let model: GameStateModel
    let onOpenDetail: (GameMenuDestination) -> Void

    @State private var selectedTab: Tab = .fleet
    @State private var collapsed = false
    @State private var settledOffset = CGSize.zero
    @GestureState private var dragOffset = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider().overlay(.white.opacity(0.2))
                content
                    .frame(width: 286, height: 158)
                Divider().overlay(.white.opacity(0.2))
                footer
            }
        }
        .frame(width: collapsed ? 172 : 306)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
        .offset(
            x: settledOffset.width + dragOffset.width,
            y: settledOffset.height + dragOffset.height
        )
        .gesture(dragGesture)
        .animation(.snappy(duration: 0.2), value: collapsed)
        .onChange(of: model.battle?.sessionID) { _, sessionID in
            if sessionID != nil {
                selectedTab = .battle
                collapsed = false
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: hasParsedData ? "waveform.path.ecg" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(hasParsedData ? .green : .orange)
                .accessibilityLabel(hasParsedData ? "游戏数据解析正常" : "等待游戏 API 数据")

            if collapsed {
                Text(collapsedTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
            } else {
                ForEach(Tab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.symbol)
                            .labelStyle(.iconOnly)
                            .frame(width: 34, height: 30)
                            .background(
                                selectedTab == tab ? Color.accentColor.opacity(0.28) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue)
                }
                Spacer()
            }

            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "展开解析数据悬浮窗" : "收起解析数据悬浮窗")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if !hasParsedData {
            ContentUnavailableView {
                Label("等待解析数据", systemImage: "network.slash")
            } description: {
                Text("进入母港后会自动读取游戏 API；该功能不需要安装根证书。")
            }
            .font(.caption)
        } else {
            switch selectedTab {
            case .fleet:
                fleetContent
            case .battle:
                battleContent
            case .quest:
                questContent
            }
        }
    }

    private var fleetContent: some View {
        let deck = model.state.fleet.decks[1]
        let ships = deck?.shipIDs.compactMap { model.state.fleet.ships[$0] } ?? []
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(deck?.name.isEmpty == false ? deck!.name : "第一舰队")
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(ships.count) 艘")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if ships.isEmpty {
                emptyLine("尚未收到母港舰队数据")
            } else {
                ForEach(ships.prefix(4), id: \.id) { ship in
                    let name = model.state.master.ships[ship.masterShipID]?.name ?? "#\(ship.masterShipID)"
                    compactShipRow(name: name, current: ship.currentHP, maximum: ship.maximumHP)
                }
                if ships.count > 4 {
                    Text("另有 \(ships.count - 4) 艘，请打开详情查看")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
    }

    private var battleContent: some View {
        Group {
            if let battle = model.battle {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(battle.kind == .practice ? "演习" : "出击战斗")
                            .font(.caption.weight(.bold))
                        Spacer()
                        Text(model.battleResult?.server.rank?.rawValue
                             ?? model.battleResult?.prediction?.rank?.rawValue
                             ?? "预测中")
                            .font(.caption.monospaced().weight(.bold))
                    }
                    HStack(alignment: .top, spacing: 12) {
                        compactBattleFleet("我方", fleet: battle.friendlyMain)
                        compactBattleFleet("敌方", fleet: battle.enemyMain)
                    }
                    if let risk = highestRisk(in: battle) {
                        Label(risk.text, systemImage: risk.symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(risk.color)
                    }
                }
                .padding(10)
            } else {
                emptyLine("进入战斗后显示双方实时 HP 与评级")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var questContent: some View {
        let active = model.quests.sortedItems.filter { $0.state >= 2 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("进行中任务")
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(active.count) 项")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if active.isEmpty {
                emptyLine("尚未收到任务列表数据")
            } else {
                ForEach(active.prefix(4)) { item in
                    HStack(spacing: 6) {
                        Text(item.title.isEmpty ? "任务 \(item.id)" : item.title)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(questProgress(item))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Text("舰队 r\(model.state.revision) · 战斗 r\(model.battleRevision) · 任务 r\(model.questRevision)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("详情") {
                onOpenDetail(selectedTab.destination)
            }
            .font(.caption2.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("打开\(selectedTab.rawValue)详情")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var hasParsedData: Bool {
        model.hasFleetData || model.battle != nil || !model.quests.items.isEmpty
    }

    private var collapsedTitle: String {
        if let battle = model.battle, battle.status != .completed {
            return "战斗解析中"
        }
        return hasParsedData ? "解析数据" : "等待 API"
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                // Bound the accumulated displacement so the panel cannot be lost
                // completely outside an iPhone landscape viewport.
                settledOffset = CGSize(
                    width: min(650, max(-20, settledOffset.width + value.translation.width)),
                    height: min(300, max(-20, settledOffset.height + value.translation.height))
                )
            }
    }

    private func compactShipRow(name: String, current: Int, maximum: Int) -> some View {
        HStack(spacing: 6) {
            statusIcon(current: current, maximum: maximum)
            Text(name)
                .font(.caption2)
                .lineLimit(1)
            Spacer()
            Text("\(current)/\(maximum)")
                .font(.caption2.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)，生命 \(current) / \(maximum)")
    }

    private func compactBattleFleet(_ title: String, fleet: BattleFleetState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
            ForEach(fleet.ships.prefix(4)) { ship in
                HStack(spacing: 4) {
                    statusIcon(current: ship.currentHP, maximum: ship.maximumHP)
                    Text("\(ship.position.index + 1)")
                    Spacer()
                    Text("\(ship.currentHP)/\(ship.maximumHP)")
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title)第 \(ship.position.index + 1) 艘，生命 \(ship.currentHP) / \(ship.maximumHP)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statusIcon(current: Int, maximum: Int) -> some View {
        let ratio = maximum > 0 ? Double(current) / Double(maximum) : 0
        let color: Color = current <= 0 ? .red : ratio <= 0.25 ? .orange : ratio <= 0.5 ? .yellow : .green
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private func questProgress(_ item: QuestListItem) -> String {
        guard let tracking = model.quests.tracking[item.id],
              let definition = model.questDefinitions[item.id],
              !definition.conditionTargets.isEmpty else {
            return "\(item.serverProgressPercent)%"
        }
        let completed = zip(tracking.counters, definition.conditionTargets)
            .filter { $0 >= $1 && $1 > 0 }.count
        return "\(completed)/\(definition.conditionTargets.count)"
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct RiskPresentation {
        let text: String
        let symbol: String
        let color: Color
    }

    private func highestRisk(in battle: BattleSnapshot) -> RiskPresentation? {
        let risks = DameconResolver.assessments(in: battle).values
        if risks.contains(.sunk) {
            return .init(text: "沉没舰存在", symbol: "xmark.octagon.fill", color: .red)
        }
        if risks.contains(.heavyDamaged) {
            return .init(text: "大破：返航建议", symbol: "exclamationmark.triangle.fill", color: .orange)
        }
        if risks.contains(.heavyDamagedWithDamecon) {
            return .init(text: "大破：损管可用", symbol: "cross.case.fill", color: .yellow)
        }
        return nil
    }
}
