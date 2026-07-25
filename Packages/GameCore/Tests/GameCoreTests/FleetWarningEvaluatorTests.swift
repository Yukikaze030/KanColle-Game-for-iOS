import XCTest
@testable import GameCore

final class FleetWarningEvaluatorTests: XCTestCase {
    private let master = FleetWarningMasterShip(id: 100, fuelMaximum: 15, ammunitionMaximum: 20)

    func testHeavyDamageBoundaryAndDameconInNormalOrExtraSlot() {
        let ships = [
            ship(id: 1, hp: 25, maxHP: 100, slots: [10]),
            ship(id: 2, hp: 24, maxHP: 100, extra: 11),
            ship(id: 3, hp: 26, maxHP: 100),
            ship(id: 4, hp: 0, maxHP: 0)
        ]
        let items = [
            10: FleetWarningItem(id: 10, category: 23),
            11: FleetWarningItem(id: 11, category: 23)
        ]
        let result = FleetWarningEvaluator.evaluate(
            ships: ships, items: items, masterShips: [100: master]
        )

        XCTAssertEqual(result.ships.map(\.heavyDamage), [
            .heavyWithDamecon, .heavyWithDamecon, .none, .none
        ])
        XCTAssertFalse(result.hasUnsafeHeavyDamage)
        XCTAssertTrue(result.hasAnyHeavyDamage)
    }

    func testRepairDockAndFiltersExcludeSortieWarning() {
        let ships = [
            ship(id: 1, level: 5, hp: 1, maxHP: 20),
            ship(id: 2, level: 99, hp: 1, maxHP: 20, locked: true),
            ship(id: 3, level: 99, hp: 1, maxHP: 20, slots: [20])
        ]
        let items = [20: FleetWarningItem(id: 20, category: 1, isLocked: true)]
        let result = FleetWarningEvaluator.evaluate(
            ships: ships,
            items: items,
            masterShips: [100: master],
            repairingShipIDs: [2],
            configuration: .init(onlyLockedShipsOrEquipment: true, minimumLevel: 10)
        )

        XCTAssertTrue(result.ships[0].wasFiltered)
        XCTAssertEqual(result.ships[0].heavyDamage, .none)
        XCTAssertTrue(result.ships[1].isInRepairDock)
        XCTAssertEqual(result.ships[1].heavyDamage, .none)
        XCTAssertEqual(result.ships[2].heavyDamage, .heavyWithoutDamecon)
    }

    func testSupplyStatesDoNotGuessWhenMasterDataMissing() {
        let unknown = FleetWarningShip(
            id: 4, masterShipID: 999, level: 1, currentHP: 10, maximumHP: 10
        )
        let result = FleetWarningEvaluator.evaluate(
            ships: [
                ship(id: 1, fuel: 15, ammunition: 20),
                ship(id: 2, fuel: 14, ammunition: 20),
                ship(id: 3, fuel: 15, ammunition: 19),
                unknown
            ],
            items: [:],
            masterShips: [100: master]
        )

        XCTAssertEqual(result.ships.map(\.supply), [.supplied, .notSupplied, .notSupplied, .unknown])
        XCTAssertTrue(result.hasUnsuppliedShip)
    }

    func testAkashiCapacityMatchesAndroidRulesAndFleetSize() {
        let repairFacility = FleetWarningItem(id: 30, category: 31)
        let normal = FleetWarningItem(id: 31, category: 1)
        let companions = (2...7).map { ship(id: $0) }

        for masterID in [182, 187] {
            let flagship = FleetWarningShip(
                id: 1, masterShipID: masterID, level: 1, currentHP: 10, maximumHP: 10,
                slotItemIDs: [30, 30, 31]
            )
            let result = FleetWarningEvaluator.evaluate(
                ships: [flagship] + companions,
                items: [30: repairFacility, 31: normal],
                masterShips: [:]
            )
            XCTAssertEqual(result.akashiRepair?.repairablePositionCount, 4)
        }

        let kai = FleetWarningShip(
            id: 1, masterShipID: 985, level: 1, currentHP: 10, maximumHP: 10,
            slotItemIDs: [30]
        )
        XCTAssertEqual(
            FleetWarningEvaluator.evaluate(
                ships: [kai, ship(id: 2)], items: [30: repairFacility], masterShips: [:]
            ).akashiRepair?.repairablePositionCount,
            2
        )
        XCTAssertNil(FleetWarningEvaluator.evaluate(
            ships: [ship(id: 1)], items: [:], masterShips: [:]
        ).akashiRepair)
    }

    private func ship(
        id: Int, level: Int = 50, hp: Int = 40, maxHP: Int = 40,
        locked: Bool = false, fuel: Int? = 15, ammunition: Int? = 20,
        slots: [Int] = [], extra: Int? = nil
    ) -> FleetWarningShip {
        FleetWarningShip(
            id: id, masterShipID: 100, level: level, currentHP: hp, maximumHP: maxHP,
            isLocked: locked, fuel: fuel, ammunition: ammunition,
            slotItemIDs: slots, extraSlotItemID: extra
        )
    }
}
