import SwiftUI
import GameCore

struct BattleLogView: View {
    let entries: [BattleLogEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "暂无战斗日志",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成战斗后会保留最近的摘要记录。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            logCard(entry)
                        }
                    }
                }
            }
        }
    }

    private func logCard(_ entry: BattleLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(location(entry.map), systemImage: "map.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(entry.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                rankLabel("预测", entry.predictedRank)
                rankLabel("实际", entry.actualRank)
                Label("\(entry.phases.count) 阶段", systemImage: "timeline.selection")
                if !entry.escapedPositions.isEmpty {
                    Label("\(entry.escapedPositions.count) 退避", systemImage: "arrowshape.turn.up.backward.fill")
                        .foregroundStyle(.cyan)
                }
            }
            .font(.caption)

            Text("我方 HP \(entry.friendlyFinalHP.reduce(0, +)) · 敌方 HP \(entry.enemyFinalHP.reduce(0, +))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let damecon = entry.dameconSummary, !damecon.isEmpty {
                Label(damecon, systemImage: "cross.case.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func rankLabel(_ title: String, _ rank: BattleRank?) -> some View {
        Text("\(title) \(rank?.rawValue ?? "—")")
            .foregroundStyle(rank == nil ? Color.secondary : Color.yellow)
    }

    private func location(_ map: BattleMapPosition?) -> String {
        guard let map else { return "未知海域" }
        var value = ""
        if let area = map.mapAreaID, let number = map.mapNumber {
            value = "\(area)-\(number)"
        }
        if let node = map.nodeID {
            value += value.isEmpty ? "节点 \(node)" : " · 节点 \(node)"
        }
        return value.isEmpty ? "未知海域" : value
    }
}
