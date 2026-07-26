import SwiftUI
import GameCore

/// Read-only native overlay. The caller owns the live browser and presentation;
/// this view never parses API JSON and never creates or reloads a WebView.
struct BattleOverlayView: View {
    let snapshot: BattleSnapshot?
    let logs: [BattleLogEntry]
    let result: BattleResultMerge?
    let shipNames: [Int: String]
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactTab: CompactTab = .live
    @State private var sideTab: SideTab = .timeline
    @State private var timelineExpanded = false

    init(
        snapshot: BattleSnapshot?,
        logs: [BattleLogEntry] = [],
        result: BattleResultMerge? = nil,
        shipNames: [Int: String] = [:],
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.logs = logs
        self.result = result
        self.shipNames = shipNames
        self.onClose = onClose
    }

    private enum CompactTab: String, CaseIterable, Identifiable {
        case live = "实时战斗"
        case log = "战斗日志"
        var id: Self { self }
    }

    private enum SideTab: String, CaseIterable, Identifiable {
        case timeline = "阶段"
        case log = "日志"
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.54).ignoresSafeArea()

                VStack(spacing: 9) {
                    BattleHeaderView(snapshot: snapshot, result: result, onClose: onClose)
                    if isRegularLayout(proxy.size) {
                        regularLayout
                    } else {
                        compactLayout
                    }
                }
                .padding(12)
                .frame(
                    width: panelWidth(proxy.size),
                    height: panelHeight(proxy.size)
                )
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
            }
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var compactLayout: some View {
        VStack(spacing: 8) {
            Picker("战斗内容", selection: $compactTab) {
                ForEach(CompactTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch compactTab {
            case .live:
                if let snapshot {
                    ScrollView {
                        VStack(spacing: 8) {
                            fleetColumns(snapshot)
                            DisclosureGroup("阶段时间线", isExpanded: $timelineExpanded) {
                                BattlePhaseTimelineView(phases: snapshot.phases)
                                    .frame(minHeight: 120, maxHeight: 220)
                                    .padding(.top, 6)
                            }
                            .padding(10)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                } else {
                    emptyBattle
                }
            case .log:
                BattleLogView(entries: logs)
            }
        }
    }

    private var regularLayout: some View {
        GeometryReader { contentProxy in
            let spacing: CGFloat = 12
            let availableWidth = max(0, contentProxy.size.width - spacing)
            if let snapshot {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        fleetColumns(snapshot)
                    }
                    .frame(width: availableWidth * 2 / 3)

                    VStack(spacing: 8) {
                        Picker("辅助内容", selection: $sideTab) {
                            ForEach(SideTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)

                        if sideTab == .timeline {
                            BattlePhaseTimelineView(phases: snapshot.phases)
                        } else {
                            BattleLogView(entries: logs)
                        }
                    }
                    .frame(width: availableWidth / 3)
                }
            } else {
                HStack(spacing: 12) {
                    emptyBattle
                        .frame(width: availableWidth * 2 / 3)
                    BattleLogView(entries: logs)
                        .frame(width: availableWidth / 3)
                }
            }
        }
    }

    private func fleetColumns(_ snapshot: BattleSnapshot) -> some View {
        HStack(alignment: .top, spacing: 9) {
            BattleFleetColumn(
                title: "我方舰队",
                side: .friendly,
                main: snapshot.friendlyMain,
                escort: snapshot.friendlyEscort,
                shipNames: shipNames
            )
            BattleFleetColumn(
                title: "敌方舰队",
                side: .enemy,
                main: snapshot.enemyMain,
                escort: snapshot.enemyEscort,
                shipNames: shipNames
            )
        }
    }

    private var emptyBattle: some View {
        ContentUnavailableView(
            "暂无进行中的战斗",
            systemImage: "scope",
            description: Text("进入战斗后，这里会显示实时 HP、损管和返航风险。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isRegularLayout(_ size: CGSize) -> Bool {
        horizontalSizeClass == .regular && size.width >= 760
    }

    private func panelWidth(_ size: CGSize) -> CGFloat {
        size.width * (isRegularLayout(size) ? 0.94 : 0.88)
    }

    private func panelHeight(_ size: CGSize) -> CGFloat {
        size.height * (isRegularLayout(size) ? 0.9 : 0.82)
    }
}
