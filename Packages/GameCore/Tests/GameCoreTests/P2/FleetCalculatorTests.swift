import XCTest
@testable import GameCore

final class FleetCalculatorTests: XCTestCase {
    func testFormula33EmptyFleetForEveryCoefficient() {
        for coefficient in 1...4 {
            let result = FleetCalculator.formula33(
                ships: [], headquartersLevel: 100, mode: .coefficient(coefficient)
            )
            XCTAssertEqual(result.value, -28)
            XCTAssertEqual(result.emptySlotBonus, 12)
        }
    }

    func testFormula33ReconRadarImprovementAndAllCoefficients() {
        let ships = [
            FleetCalculator.Formula33Ship(
                position: 1,
                totalSearch: 30,
                equipment: [
                    .init(type: 10, search: 8, improvement: 4),
                    .init(type: 12, search: 5, improvement: 9)
                ]
            ),
            FleetCalculator.Formula33Ship(
                position: 2,
                totalSearch: 20,
                equipment: [.init(type: 9, search: 9, improvement: 0)]
            )
        ]

        let expected = [1: 10.16, 2: 36.89, 3: 63.62, 4: 90.35]
        for coefficient in 1...4 {
            let result = FleetCalculator.formula33(
                ships: ships, headquartersLevel: 80, mode: .coefficient(coefficient)
            )
            XCTAssertEqual(result.value, expected[coefficient]!, accuracy: 1e-6)
        }
        XCTAssertEqual(
            FleetCalculator.formula33(ships: ships, headquartersLevel: 80, mode: .pureSearch).value,
            50,
            accuracy: 1e-6
        )
    }

    func testFormula33MissingEquipmentAndExcludedPosition() {
        let ships = [
            FleetCalculator.Formula33Ship(
                position: 1,
                totalSearch: 12,
                equipment: [nil, .init(type: 8, search: 4)]
            ),
            FleetCalculator.Formula33Ship(position: 2, totalSearch: 40)
        ]
        let result = FleetCalculator.formula33(
            ships: ships,
            headquartersLevel: 1,
            mode: .coefficient(1),
            excludedPositions: [2]
        )
        XCTAssertEqual(result.shipContribution, sqrt(8), accuracy: 1e-12)
        XCTAssertEqual(result.equipmentContribution, 3.2, accuracy: 1e-12)
        XCTAssertEqual(result.emptySlotBonus, 10)
        XCTAssertEqual(result.value, 15.02, accuracy: 1e-6)
    }

    func testFormula33EquipmentTypeSpecificImprovementTerms() {
        let level = 4
        let cases: [(Int, Double)] = [
            (8, 4.0), (9, 7.4), (94, 7.4), (10, 8.88),
            (11, 8.03), (13, 4.68), (12, 4.5), (41, 4.44), (1, 3.0)
        ]
        for (type, expected) in cases {
            let value = FleetCalculator.formula33EquipmentContribution(
                .init(type: type, search: 5, improvement: level)
            )
            XCTAssertEqual(value, expected, accuracy: 1e-12, "type=\(type)")
        }
    }

    func testAirPowerZeroSlotNonAircraftAndExpansionAreIgnored() {
        let range = FleetCalculator.airPowerRange(slots: [
            .init(position: 1, itemID: 1, type: 6, antiAir: 10, aircraftCount: 0, proficiency: 7),
            .init(position: 1, itemID: 2, type: 12, antiAir: 20, aircraftCount: 18, proficiency: 7),
            .init(position: 1, itemID: 3, type: 6, antiAir: 10, aircraftCount: 18, proficiency: 7, isExpansionSlot: true)
        ])
        XCTAssertEqual(range, .init(minimum: 0, maximum: 0))
    }

    func testAirPowerNormalFullMasteryAndImprovementRange() {
        let range = FleetCalculator.airPowerRange(slots: [
            .init(position: 1, itemID: 1, type: 6, antiAir: 10, aircraftCount: 18, proficiency: 0),
            .init(position: 1, itemID: 2, type: 8, antiAir: 3, aircraftCount: 18, proficiency: 7),
            .init(position: 2, itemID: 60, type: 7, antiAir: 4, aircraftCount: 12, improvement: 4, proficiency: 7),
            .init(position: 2, itemID: 4, type: 45, antiAir: 5, aircraftCount: 4, improvement: 10, proficiency: 7)
        ])
        XCTAssertEqual(range.minimum, 116)
        XCTAssertEqual(range.maximum, 118)
        XCTAssertEqual(
            FleetCalculator.airPowerRange(slots: [
                .init(position: 1, itemID: 1, type: 6, antiAir: 10, aircraftCount: 18, proficiency: 7),
                .init(position: 2, itemID: 4, type: 45, antiAir: 5, aircraftCount: 4, improvement: 10, proficiency: 7)
            ], excludedPositions: [2]),
            .init(minimum: 67, maximum: 67)
        )
    }

    func testMoraleStatesThresholdMinimumAndExclusion() {
        let result = FleetCalculator.morale(
            ships: [
                .init(position: 1, condition: 50),
                .init(position: 2, condition: 49),
                .init(position: 3, condition: 39),
                .init(position: 4, condition: 29),
                .init(position: 5, condition: 19)
            ],
            threshold: 40,
            excludedPositions: [5]
        )
        XCTAssertEqual(result.ships.map(\.state), [.sparkling, .normal, .lightFatigue, .orangeFatigue])
        XCTAssertEqual(result.ships.map(\.isBelowThreshold), [false, false, true, true])
        XCTAssertEqual(result.minimumCondition, 29)
        XCTAssertFalse(result.isReady)

        let custom = FleetCalculator.morale(ships: [.init(position: 1, condition: 45)], threshold: 49)
        XCTAssertEqual(custom.ships.first?.state, .normal)
        XCTAssertTrue(custom.ships.first?.isBelowThreshold == true)
    }

    func testEmptyFleetMoraleMatchesAndroidSentinel() {
        let result = FleetCalculator.morale(ships: [])
        XCTAssertEqual(result.minimumCondition, 100)
        XCTAssertTrue(result.isReady)
    }
}
