import SwiftUI
import GameCore

struct ShipStatusRow: View {
    let ship: UserShip
    let name: String
    let warning: FleetShipWarning?

    init(ship: UserShip, name: String, warning: FleetShipWarning? = nil) {
        self.ship = ship
        self.name = name
        self.warning = warning
    }

    private var hpFraction: Double {
        guard ship.maximumHP > 0 else { return 0 }
        return min(1, max(0, Double(ship.currentHP) / Double(ship.maximumHP)))
    }

    private var conditionLabel: String {
        switch ship.condition {
        case 50...: "士气高涨"
        case 40...: "士气良好"
        case 30...: "轻度疲劳"
        case 20...: "疲劳"
        default: "严重疲劳"
        }
    }

    private var statusColor: Color {
        if warning?.heavyDamage == .heavyWithoutDamecon { return .red }
        if warning?.heavyDamage == .heavyWithDamecon { return .orange }
        if hpFraction <= 0.5 { return .orange }
        return .green
    }

    private var statusText: String {
        if warning?.isInRepairDock == true { return "入渠中" }
        if warning?.heavyDamage == .heavyWithoutDamecon { return "大破·无损管" }
        if warning?.heavyDamage == .heavyWithDamecon { return "大破·有损管" }
        if warning?.supply == .notSupplied { return "未补给" }
        return "HP \(ship.currentHP)/\(ship.maximumHP)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ship.isHeavilyDamaged ? "exclamationmark.triangle.fill" : "shield.lefthalf.filled")
                .foregroundStyle(statusColor)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Lv.\(ship.level)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: hpFraction)
                    .tint(statusColor)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(statusText)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(statusColor)
                Text("\(conditionLabel) · \(ship.condition)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .background(statusColor.opacity(ship.isHeavilyDamaged ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if ship.isHeavilyDamaged {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red)
                    .frame(width: 4)
                    .padding(.vertical, 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name)，等级 \(ship.level)，\(statusText)，\(conditionLabel) \(ship.condition)")
    }
}
