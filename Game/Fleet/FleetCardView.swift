import SwiftUI
import GameCore

struct FleetCardView: View {
    let deck: FleetDeck
    let ships: [UserShip]
    let masterData: GameMasterData

    init(deck: FleetDeck, ships: [UserShip], masterData: GameMasterData) {
        self.deck = deck
        self.ships = ships
        self.masterData = masterData
    }

    private var damagedShips: [UserShip] { ships.filter(\.isHeavilyDamaged) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(deck.name.isEmpty ? "第\(deck.id)舰队" : deck.name)
                    .font(.headline)
                Text("\(ships.count) 艘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let expedition = deck.expedition, expedition.isActive {
                    Label("远征中", systemImage: "paperplane.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
            }

            if !damagedShips.isEmpty {
                FleetWarningBanner(
                    title: "大破警告",
                    detail: damagedShips.map(shipName).joined(separator: "、")
                )
            }

            if ships.isEmpty {
                Text("该舰队尚未编成舰船")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(ships, id: \.id) { ship in
                        ShipStatusRow(ship: ship, name: shipName(ship))
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private func shipName(_ ship: UserShip) -> String {
        let name = masterData.ships[ship.masterShipID]?.name ?? ""
        return name.isEmpty ? "舰船 #\(ship.masterShipID)" : name
    }
}
