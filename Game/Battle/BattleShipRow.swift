import SwiftUI
import GameCore

enum BattleFleetSide: String {
    case friendly = "我方"
    case enemy = "敌方"
}

struct BattleShipRow: View {
    let ship: BattleShipState
    let name: String
    let side: BattleFleetSide

    @State private var showsDetails = false

    private struct Status: Identifiable {
        let text: String
        let symbol: String
        let color: Color
        var id: String { "\(symbol)-\(text)" }
    }

    private var hpFraction: Double {
        guard ship.maximumHP > 0 else { return 0 }
        return min(1, max(0, Double(ship.currentHP) / Double(ship.maximumHP)))
    }

    private var isHeavyDamage: Bool {
        ship.maximumHP > 0 && ship.currentHP > 0 && ship.currentHP * 4 <= ship.maximumHP
    }

    private var statuses: [Status] {
        var values: [Status] = []
        if ship.escaped {
            values.append(.init(text: "退避", symbol: "arrowshape.turn.up.backward.fill", color: .cyan))
        }
        if ship.currentHP <= 0 {
            values.append(.init(text: "沉没", symbol: "xmark.octagon.fill", color: .red))
        } else if isHeavyDamage {
            values.append(.init(text: "大破", symbol: "exclamationmark.triangle.fill", color: .orange))
        }
        if let damecon = ship.damecon {
            values.append(damecon.consumed
                ? .init(text: "损管发动", symbol: "cross.case.fill", color: .purple)
                : .init(text: "损管待命", symbol: "cross.case", color: .yellow))
        }
        if values.isEmpty {
            values.append(.init(text: "战斗中", symbol: "shield.lefthalf.filled", color: hpFraction <= 0.5 ? .orange : .green))
        }
        return values
    }

    private var dominantColor: Color {
        if ship.currentHP <= 0 { return .red }
        if ship.escaped { return .cyan }
        if isHeavyDamage { return .orange }
        if ship.damecon?.consumed == true { return .purple }
        return hpFraction <= 0.5 ? .orange : .green
    }

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            HStack(spacing: 8) {
                Text("\(ship.position.index + 1)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Spacer(minLength: 2)
                        Text("\(ship.currentHP)/\(ship.maximumHP)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(dominantColor)
                    }

                    ProgressView(value: hpFraction)
                        .tint(dominantColor)
                        .accessibilityHidden(true)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(statuses) { status in
                                Label(status.text, systemImage: status.symbol)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(status.color)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(status.color.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    .scrollClipDisabled()
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(dominantColor.opacity(isHeavyDamage || ship.currentHP <= 0 ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dominantColor)
                    .frame(width: 4)
                    .padding(.vertical, 5)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsDetails) {
            details
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("轻点查看详细状态")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(name, systemImage: side == .friendly ? "shield.fill" : "scope")
                .font(.headline)
            Text("\(side.rawValue) · \(BattleUILabels.fleetComponent(ship.position.component))第 \(ship.position.index + 1) 舰")
            LabeledContent("当前 HP", value: "\(ship.currentHP) / \(ship.maximumHP)")
            LabeledContent("战斗开始 HP", value: "\(ship.initialHP)")
            if let level = ship.level {
                LabeledContent("等级", value: "\(level)")
            }
            if let damecon = ship.damecon {
                LabeledContent(
                    "损管",
                    value: damecon.kind == .goddess ? "女神" : "修理要员"
                )
                LabeledContent("损管状态", value: damecon.consumed ? "已发动" : "待命")
            }
            if ship.escaped {
                Label("该舰已退避，不参与返航大破警告", systemImage: "arrowshape.turn.up.backward.fill")
                    .foregroundStyle(.cyan)
            }
        }
        .font(.subheadline)
        .padding(16)
        .frame(idealWidth: 310)
    }

    private var accessibilityText: String {
        let state = statuses.map(\.text).joined(separator: "、")
        return "\(side.rawValue)，\(BattleUILabels.fleetComponent(ship.position.component))第 \(ship.position.index + 1) 舰，\(name)，HP \(ship.currentHP) / \(ship.maximumHP)，\(state)"
    }
}
