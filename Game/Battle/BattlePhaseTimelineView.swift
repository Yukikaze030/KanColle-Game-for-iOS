import SwiftUI
import GameCore

struct BattlePhaseTimelineView: View {
    let phases: [BattlePhaseResult]

    private struct Summary: Identifiable {
        let id: Int
        let kind: BattlePhaseKind
        let friendlyDamage: Int
        let enemyDamage: Int
        let hitCount: Int
        let warningCount: Int
    }

    private var summaries: [Summary] {
        phases.enumerated().map { index, phase in
            Summary(
                id: index,
                kind: phase.kind,
                friendlyDamage: phase.events
                    .filter(\.targetIsFriendly)
                    .reduce(0) { $0 + $1.damage },
                enemyDamage: phase.events
                    .filter { !$0.targetIsFriendly }
                    .reduce(0) { $0 + $1.damage },
                hitCount: phase.events.count,
                warningCount: phase.warnings.count
            )
        }
    }

    var body: some View {
        Group {
            if summaries.isEmpty {
                ContentUnavailableView(
                    "暂无阶段记录",
                    systemImage: "timeline.selection",
                    description: Text("收到战斗数据后会显示阶段摘要。")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(summaries) { summary in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: summary.warningCount > 0
                                      ? "exclamationmark.triangle.fill"
                                      : "circle.inset.filled")
                                    .foregroundStyle(summary.warningCount > 0 ? .orange : .cyan)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(BattleUILabels.phase(summary.kind))
                                        .font(.subheadline.weight(.semibold))
                                    Text("我方受伤 \(summary.friendlyDamage) · 敌方受伤 \(summary.enemyDamage) · \(summary.hitCount) 次命中")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if summary.warningCount > 0 {
                                        Label("\(summary.warningCount) 条解析提示", systemImage: "exclamationmark.bubble")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "\(BattleUILabels.phase(summary.kind))，我方受伤 \(summary.friendlyDamage)，敌方受伤 \(summary.enemyDamage)，\(summary.hitCount) 次命中，\(summary.warningCount) 条提示"
                            )
                        }
                    }
                }
            }
        }
    }
}
