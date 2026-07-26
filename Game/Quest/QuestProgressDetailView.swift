import SwiftUI
import GameCore

struct QuestProgressDetailView: View {
    let item: QuestListItem
    let definition: QuestDefinition?
    let tracking: QuestTrackingState?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                serverProgress
                exactProgress
                resetInformation

                if !item.detail.isEmpty {
                    GroupBox("任务说明") {
                        Text(item.detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                if definition == nil {
                    Label(
                        "缺少此任务的静态定义，标题与进度来自游戏服务器。",
                        systemImage: "questionmark.folder.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("静态定义缺失，当前使用服务器数据")
                }
            }
            .padding(12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(definition?.code ?? "No.\(item.id)")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stateLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(stateColor)
            }
            Text(item.title.isEmpty ? "未知任务 No.\(item.id)" : item.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var serverProgress: some View {
        GroupBox("服务器进度") {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(item.serverProgressPercent), total: 100)
                    .tint(item.state == 3 ? .green : .accentColor)
                    .accessibilityLabel("服务器进度")
                    .accessibilityValue("百分之 \(item.serverProgressPercent)")
                HStack {
                    Text("\(item.serverProgressPercent)%")
                        .font(.headline.monospacedDigit())
                    if item.precision == .serverOnly || exactConditions == nil {
                        Label("服务器估算", systemImage: "approximate")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var exactProgress: some View {
        if let conditions = exactConditions {
            GroupBox(conditions.count > 1 ? "精确进度 · 多条件逐项统计" : "精确进度") {
                VStack(alignment: .leading, spacing: 10) {
                    if conditions.count > 1 {
                        let done = conditions.filter(\.isComplete).count
                        Text("已满足 \(done)/\(conditions.count) 项条件。各条件独立计算，不使用简单平均值。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(conditions) { condition in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label("条件 \(condition.index + 1)", systemImage: condition.isComplete ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(condition.isComplete ? .green : .primary)
                                Spacer()
                                Text("\(condition.counter)/\(condition.target)")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            }
                            ProgressView(
                                value: Double(min(condition.counter, condition.target)),
                                total: Double(max(1, condition.target))
                            )
                            .tint(condition.isComplete ? .green : .cyan)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("条件 \(condition.index + 1)，\(condition.counter) 次，共需 \(condition.target) 次，\(condition.isComplete ? "已满足" : "未满足")")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            GroupBox("精确进度") {
                Label(
                    "此任务暂不支持精确计数，显示游戏服务器估算。",
                    systemImage: "approximate"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var resetInformation: some View {
        if let definition, definition.resetKind != .none {
            GroupBox("重置时间") {
                if let reset = QuestResetCalendar().nextReset(
                    after: Date(), questID: item.id, resetKind: definition.resetKind
                ) {
                    Label {
                        Text(formattedReset(reset))
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct Condition: Identifiable {
        let index: Int
        let counter: Int
        let target: Int
        var id: Int { index }
        var isComplete: Bool { counter >= target }
    }

    private var exactConditions: [Condition]? {
        guard item.precision == .exact,
              let definition,
              !definition.conditionTargets.isEmpty,
              let tracking else { return nil }
        return definition.conditionTargets.enumerated().map { index, target in
            Condition(
                index: index,
                counter: tracking.counters.indices.contains(index) ? tracking.counters[index] : 0,
                target: max(1, target)
            )
        }
    }

    private var stateLabel: String {
        switch item.state {
        case 3: "已完成"
        case 2: "已接"
        default: "未接"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case 3: .green
        case 2: .cyan
        default: .secondary
        }
    }

    private func formattedReset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = QuestResetCalendar.tokyoTimeZone
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date) + " JST"
    }
}
