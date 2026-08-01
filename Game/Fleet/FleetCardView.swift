import SwiftUI
import GameCore

struct FleetCardView: View {
    let deck: FleetDeck
    let ships: [UserShip]
    let masterData: GameMasterData
    let userItems: [Int: UserSlotItem]
    let repairingShipIDs: Set<Int>
    let headquartersLevel: Int
    let warningConfiguration: FleetWarningConfiguration

    init(
        deck: FleetDeck,
        ships: [UserShip],
        masterData: GameMasterData,
        userItems: [Int: UserSlotItem],
        repairingShipIDs: Set<Int>,
        headquartersLevel: Int,
        warningConfiguration: FleetWarningConfiguration = .init()
    ) {
        self.deck = deck
        self.ships = ships
        self.masterData = masterData
        self.userItems = userItems
        self.repairingShipIDs = repairingShipIDs
        self.headquartersLevel = headquartersLevel
        self.warningConfiguration = warningConfiguration
    }

    private var formula33Search: FleetCalculator.Formula33Result {
        FleetCalculator.formula33(
            ships: ships.enumerated().map { index, ship in
                FleetCalculator.Formula33Ship(
                    position: index + 1,
                    totalSearch: ship.search ?? 0,
                    equipment: ship.slotItemIDs.map { itemID in
                        guard let userItem = userItems[itemID],
                              let masterItem = masterData.slotItems[userItem.masterSlotItemID],
                              let category = masterItem.category else { return nil }
                        return FleetCalculator.Formula33Equipment(
                            type: category,
                            search: masterItem.search ?? 0,
                            improvement: userItem.improvementLevel
                        )
                    },
                    expansionEquipment: ship.extraSlotItemID.flatMap { itemID in
                        guard let userItem = userItems[itemID],
                              let masterItem = masterData.slotItems[userItem.masterSlotItemID],
                              let category = masterItem.category else { return nil }
                        return FleetCalculator.Formula33Equipment(
                            type: category,
                            search: masterItem.search ?? 0,
                            improvement: userItem.improvementLevel
                        )
                    }
                )
            },
            headquartersLevel: headquartersLevel,
            mode: .coefficient(4)
        )
    }

    private var airPower: FleetCalculator.AirPowerRange {
        FleetCalculator.airPowerRange(
            slots: ships.enumerated().flatMap { shipIndex, ship in
                ship.slotItemIDs.enumerated().compactMap { slotIndex, itemID in
                    guard let userItem = userItems[itemID],
                          let masterItem = masterData.slotItems[userItem.masterSlotItemID],
                          let category = masterItem.category else { return nil }
                    return FleetCalculator.AircraftSlot(
                        position: shipIndex + 1,
                        itemID: masterItem.id,
                        type: category,
                        antiAir: masterItem.antiAir ?? 0,
                        aircraftCount: ship.aircraftCounts.indices.contains(slotIndex) ? ship.aircraftCounts[slotIndex] : 0,
                        improvement: userItem.improvementLevel,
                        proficiency: userItem.aircraftProficiency
                    )
                }
            }
        )
    }

    private var warnings: FleetWarningResult {
        FleetWarningEvaluator.evaluate(
            ships: ships.map {
                FleetWarningShip(
                    id: $0.id,
                    masterShipID: $0.masterShipID,
                    level: $0.level,
                    currentHP: $0.currentHP,
                    maximumHP: $0.maximumHP,
                    isLocked: $0.locked,
                    fuel: $0.fuel,
                    ammunition: $0.ammunition,
                    slotItemIDs: $0.slotItemIDs,
                    extraSlotItemID: $0.extraSlotItemID
                )
            },
            items: Dictionary(uniqueKeysWithValues: userItems.values.compactMap { item in
                guard let category = masterData.slotItems[item.masterSlotItemID]?.category else {
                    return nil
                }
                return (item.id, FleetWarningItem(id: item.id, category: category, isLocked: item.locked))
            }),
            masterShips: Dictionary(uniqueKeysWithValues: masterData.ships.values.map {
                ($0.id, FleetWarningMasterShip(
                    id: $0.id,
                    fuelMaximum: $0.fuelMaximum,
                    ammunitionMaximum: $0.ammunitionMaximum
                ))
            }),
            repairingShipIDs: repairingShipIDs,
            configuration: warningConfiguration
        )
    }

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

            if warnings.hasUnsafeHeavyDamage {
                FleetWarningBanner(
                    title: "大破且无损管",
                    detail: ships.filter { ship in
                        warnings.ships.first(where: { $0.shipID == ship.id })?.heavyDamage
                            == .heavyWithoutDamecon
                    }.map(shipName).joined(separator: "、")
                )
            } else if warnings.hasAnyHeavyDamage {
                FleetWarningBanner(
                    title: "大破（已装备损管）",
                    detail: "出击前仍请确认装备与舰队状态。",
                    tint: .orange
                )
            }

            if !ships.isEmpty {
                HStack(spacing: 8) {
                    FleetMetric(label: "索敌(33式·4)", value: String(format: "%.2f", formula33Search.value), icon: "eye.fill")
                    FleetMetric(
                        label: "制空",
                        value: airPower.minimum == airPower.maximum
                            ? "\(airPower.minimum)"
                            : "\(airPower.minimum)–\(airPower.maximum)",
                        icon: "airplane"
                    )
                }
            }

            if ships.isEmpty {
                Text("该舰队尚未编成舰船")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(ships, id: \.id) { ship in
                        ShipStatusRow(
                            ship: ship,
                            name: shipName(ship),
                            warning: warnings.ships.first { $0.shipID == ship.id }
                        )
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

private struct FleetMetric: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.cyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
    }
}
