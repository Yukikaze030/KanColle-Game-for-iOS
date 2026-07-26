import SwiftUI
import GameCore

struct BattleFleetColumn: View {
    let title: String
    let side: BattleFleetSide
    let main: BattleFleetState
    let escort: BattleFleetState?
    let shipNames: [Int: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: side == .friendly ? "shield.fill" : "scope")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(side == .friendly ? .cyan : .pink)

            fleetSection("主力", ships: main.ships)
            if let escort, !escort.ships.isEmpty {
                fleetSection("护卫", ships: escort.ships)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.11), lineWidth: 1)
        }
    }

    private func fleetSection(_ label: String, ships: [BattleShipState]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(ships) { ship in
                BattleShipRow(
                    ship: ship,
                    name: displayName(for: ship),
                    side: side
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(side.rawValue)\(label)舰队")
    }

    private func displayName(for ship: BattleShipState) -> String {
        if let masterID = ship.masterShipID,
           let name = shipNames[masterID], !name.isEmpty {
            return name
        }
        if case let .friendlyUserShip(userShipID) = ship.id,
           let name = shipNames[userShipID], !name.isEmpty {
            return name
        }
        if let masterID = ship.masterShipID {
            return "舰船 #\(masterID)"
        }
        return side == .friendly
            ? "\(BattleUILabels.fleetComponent(ship.position.component))舰 \(ship.position.index + 1)"
            : "敌舰 \(ship.position.index + 1)"
    }
}
