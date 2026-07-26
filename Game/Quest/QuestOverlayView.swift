import SwiftUI
import GameCore

/// Read-only native quest overlay. Filtering is entirely local; this view does not
/// parse API JSON, issue game requests, or create another WebView.
struct QuestOverlayView: View {
    let snapshot: QuestListSnapshot
    let definitions: [Int: QuestDefinition]?
    let isStale: Bool
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filter: QuestListFilter = .accepted
    @State private var selectedQuestID: Int?

    init(
        snapshot: QuestListSnapshot,
        definitions: [Int: QuestDefinition]? = nil,
        isStale: Bool,
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.definitions = definitions
        self.isStale = isStale
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.58).ignoresSafeArea()

                VStack(spacing: 9) {
                    header
                    statusBanners
                    if isRegularLayout(proxy.size) {
                        regularLayout
                    } else {
                        compactLayout
                    }
                }
                .padding(12)
                .frame(width: panelWidth(proxy.size), height: panelHeight(proxy.size))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { repairSelection() }
        .onChange(of: filter) { _, _ in repairSelection() }
        .onChange(of: snapshot.updatedAt) { _, _ in repairSelection() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("任务", systemImage: "checklist")
                .font(.headline)
            Text("\(filteredItems.count) 项")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if let updatedAt = snapshot.updatedAt {
                Text("更新于 \(updatedAt, format: .dateTime.hour().minute().second())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Label("关闭", systemImage: "xmark.circle.fill")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("关闭任务覆盖页并返回游戏")
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if isStale {
            statusBanner(
                "当前为恢复数据，等待游戏任务列表刷新后自动更新。",
                systemImage: "clock.badge.exclamationmark",
                color: .orange
            )
        }
        if definitions == nil || definitions?.isEmpty == true {
            statusBanner(
                "静态任务定义尚未加载；标题、详情与百分比使用服务器数据。",
                systemImage: "questionmark.folder.fill",
                color: .yellow
            )
        }
        if resetJustOccurred {
            statusBanner(
                "日本时间重置刚发生，精确计数可能暂为零，请等待下一次任务列表同步。",
                systemImage: "arrow.clockwise.circle.fill",
                color: .cyan
            )
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 8) {
            QuestFilterBar(selection: $filter, counts: filterCounts)
            questList(showSelection: false)
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 10) {
                QuestFilterBar(selection: $filter, counts: filterCounts, vertical: true)
                questList(showSelection: true)
            }
            .frame(maxWidth: 430)

            Divider()

            Group {
                if let selectedItem {
                    QuestProgressDetailView(
                        item: selectedItem,
                        definition: definitions?[selectedItem.id],
                        tracking: snapshot.tracking[selectedItem.id]
                    )
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func questList(showSelection: Bool) -> some View {
        Group {
            if filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            if showSelection {
                                Button {
                                    selectedQuestID = item.id
                                } label: {
                                    QuestRowView(
                                        item: item,
                                        definition: definitions?[item.id],
                                        tracking: snapshot.tracking[item.id],
                                        isSelected: selectedQuestID == item.id
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                DisclosureGroup {
                                    QuestProgressDetailView(
                                        item: item,
                                        definition: definitions?[item.id],
                                        tracking: snapshot.tracking[item.id]
                                    )
                                    .frame(minHeight: 180, maxHeight: 300)
                                } label: {
                                    QuestRowView(
                                        item: item,
                                        definition: definitions?[item.id],
                                        tracking: snapshot.tracking[item.id],
                                        isSelected: false
                                    )
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            emptyTitle,
            systemImage: "checklist.unchecked",
            description: Text(emptyDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBanner(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
    }

    private var filteredItems: [QuestListItem] {
        allItems.filter { item in
            switch filter {
            case .accepted: item.state == 2
            case .trackable: isTrackable(item)
            case .completed: item.state == 3
            case .all: true
            }
        }
    }

    private var allItems: [QuestListItem] {
        snapshot.sortedItems
    }

    private var selectedItem: QuestListItem? {
        guard let selectedQuestID else { return filteredItems.first }
        return filteredItems.first { $0.id == selectedQuestID } ?? filteredItems.first
    }

    private var filterCounts: [QuestListFilter: Int] {
        [
            .accepted: allItems.filter { $0.state == 2 }.count,
            .trackable: allItems.filter(isTrackable).count,
            .completed: allItems.filter { $0.state == 3 }.count,
            .all: allItems.count
        ]
    }

    private func isTrackable(_ item: QuestListItem) -> Bool {
        guard item.precision == .exact,
              let definition = definitions?[item.id],
              !definition.conditionTargets.isEmpty,
              snapshot.tracking[item.id] != nil else { return false }
        return true
    }

    private var resetJustOccurred: Bool {
        let now = Date()
        let calendar = QuestResetCalendar()
        return definitions?.values.contains { definition in
            guard let start = calendar.periodStart(
                containing: now, questID: definition.id, resetKind: definition.resetKind
            ) else { return false }
            return now.timeIntervalSince(start) >= 0 && now.timeIntervalSince(start) < 10 * 60
        } ?? false
    }

    private var emptyTitle: String {
        if snapshot.items.isEmpty { return "尚未取得任务列表" }
        return switch filter {
        case .accepted: "没有已接任务"
        case .trackable: "没有可精确追踪任务"
        case .completed: "没有已完成任务"
        case .all: "任务列表为空"
        }
    }

    private var emptyDescription: String {
        if snapshot.items.isEmpty {
            return isStale ? "恢复快照中没有任务，进入任务页面后会同步。" : "请在游戏中打开任务页面以同步数据。"
        }
        return "可切换顶部筛选查看其他任务。"
    }

    private func repairSelection() {
        guard !filteredItems.contains(where: { $0.id == selectedQuestID }) else { return }
        selectedQuestID = filteredItems.first?.id
    }

    private func isRegularLayout(_ size: CGSize) -> Bool {
        horizontalSizeClass == .regular && size.width >= 760
    }

    private func panelWidth(_ size: CGSize) -> CGFloat {
        size.width * (isRegularLayout(size) ? 0.95 : 0.9)
    }

    private func panelHeight(_ size: CGSize) -> CGFloat {
        size.height * (isRegularLayout(size) ? 0.92 : 0.86)
    }
}
