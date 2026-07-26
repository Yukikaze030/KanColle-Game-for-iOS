import SwiftUI
import GameCore

struct BattleHeaderView: View {
    let snapshot: BattleSnapshot?
    let result: BattleResultMerge?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("战斗", systemImage: "scope")
                .font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                Text(locationText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(formationText, systemImage: "arrow.triangle.branch")
                    Label(phaseText, systemImage: "waveform.path.ecg")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            rankBadge(
                title: "预测",
                rank: result?.prediction?.rank,
                fallback: result?.prediction?.confidence == .degraded ? "待确认" : "—"
            )
            rankBadge(
                title: "实际",
                rank: result?.server.rank,
                fallback: result?.server.rawRank ?? "—"
            )

            Button(action: onClose) {
                Label("关闭", systemImage: "xmark.circle.fill")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("关闭战斗覆盖页并返回游戏")
        }
        .accessibilityElement(children: .contain)
    }

    private var locationText: String {
        guard let map = snapshot?.map else { return "海域与节点待获取" }
        var parts: [String] = []
        if let area = map.mapAreaID, let number = map.mapNumber {
            parts.append("\(area)-\(number)")
        }
        if let node = map.nodeID {
            parts.append("节点 \(node)")
        }
        if map.isBoss {
            parts.append("Boss")
        }
        return parts.isEmpty ? "海域与节点待获取" : parts.joined(separator: " · ")
    }

    private var formationText: String {
        guard let formation = snapshot?.formation else { return "阵型待获取" }
        return "我 \(formation.friendly) / 敌 \(formation.enemy) / 航向 \(formation.engagement)"
    }

    private var phaseText: String {
        guard let phase = snapshot?.phases.last?.kind else { return "等待战斗数据" }
        return BattleUILabels.phase(phase)
    }

    private func rankBadge(title: String, rank: BattleRank?, fallback: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(rank?.rawValue ?? fallback)
                .font(.headline.monospaced())
                .foregroundStyle(rank == nil ? Color.secondary : Color.yellow)
        }
        .frame(minWidth: 42, minHeight: 40)
        .padding(.horizontal, 6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)评级 \(rank?.rawValue ?? fallback)")
    }
}

enum BattleUILabels {
    static func phase(_ phase: BattlePhaseKind) -> String {
        switch phase {
        case .initialization: "战斗开始"
        case .airBase: "基地航空队"
        case .aerial: "航空战"
        case .support: "支援舰队"
        case .openingAntiSubmarine: "先制反潜"
        case .openingTorpedo: "开幕雷击"
        case .shelling: "炮击战"
        case .torpedo: "雷击战"
        case .friendlyFleet: "友军舰队"
        case .night: "夜战"
        }
    }

    static func fleetComponent(_ component: BattleFleetComponent) -> String {
        component == .main ? "主力" : "护卫"
    }
}
