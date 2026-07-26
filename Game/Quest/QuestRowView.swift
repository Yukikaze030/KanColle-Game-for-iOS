import SwiftUI
import GameCore

struct QuestRowView: View {
    let item: QuestListItem
    let definition: QuestDefinition?
    let tracking: QuestTrackingState?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(categoryLabel)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(categoryColor.opacity(0.22), in: Capsule())
                    .foregroundStyle(categoryColor)

                Text("No.\(item.id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(item.title.isEmpty ? "未知任务" : item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Spacer(minLength: 0)

                if item.state == 3 {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("已完成")
                }
            }

            HStack(spacing: 10) {
                Label("服务器 \(item.serverProgressPercent)%", systemImage: "chart.bar.fill")
                    .accessibilityLabel("服务器进度百分之 \(item.serverProgressPercent)")

                if let exactSummary {
                    Label(exactSummary, systemImage: "scope")
                        .foregroundStyle(.cyan)
                } else {
                    Label("服务器估算", systemImage: "approximate")
                        .foregroundStyle(.orange)
                }

                if let resetText {
                    Label(resetText, systemImage: "clock.arrow.circlepath")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("打开任务进度详情")
    }

    private var exactSummary: String? {
        guard item.precision == .exact,
              let definition,
              !definition.conditionTargets.isEmpty,
              let tracking else { return nil }

        if definition.conditionTargets.count == 1 {
            return "\(tracking.counters.first ?? 0)/\(definition.conditionTargets[0])"
        }
        let completed = zip(tracking.counters, definition.conditionTargets)
            .filter { $0.0 >= $0.1 }.count
        return "条件 \(completed)/\(definition.conditionTargets.count) · 逐项查看"
    }

    private var resetText: String? {
        guard let definition,
              let reset = QuestResetCalendar().nextReset(
                after: Date(), questID: item.id, resetKind: definition.resetKind
              ) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = QuestResetCalendar.tokyoTimeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: reset) + " JST"
    }

    private var categoryLabel: String {
        switch item.category {
        case 1: "编成"
        case 2: "出击"
        case 3: "演习"
        case 4: "远征"
        case 5: "补给"
        case 6: "工厂"
        case 7: "改装"
        case 8: "出击"
        case 9: "其他"
        default: "类型 \(item.category)"
        }
    }

    private var categoryColor: Color {
        switch item.category {
        case 2, 8: .red
        case 3: .orange
        case 4: .green
        case 6: .purple
        default: .blue
        }
    }

    private var accessibilitySummary: String {
        let title = item.title.isEmpty ? "未知任务" : item.title
        return "任务 \(item.id)，\(title)，\(categoryLabel)，服务器进度百分之 \(item.serverProgressPercent)，\(exactSummary ?? "服务器估算")，\(resetText ?? "无重置时间")"
    }
}
