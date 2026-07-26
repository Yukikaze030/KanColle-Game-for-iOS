import XCTest
@testable import GameCore

final class BattleRankPredictorTests: XCTestCase {
    private let predictor = BattleRankPredictor()

    func testEnemyAnnihilationRanksSSWithoutDamageAndSWithDamage() {
        XCTAssertEqual(predict(friend: [30, 30], friendAfter: [30, 30], enemy: [20, 20], enemyAfter: [0, 0]).rank, .ss)
        XCTAssertEqual(predict(friend: [30, 30], friendAfter: [29, 30], enemy: [20, 20], enemyAfter: [0, 0]).rank, .s)
    }

    func testAndroidGoldenRanksAThroughE() {
        XCTAssertEqual(predict(friend: [30, 30, 30], friendAfter: [30, 30, 30], enemy: [10, 10, 10], enemyAfter: [0, 0, 10]).rank, .a)
        XCTAssertEqual(predict(friend: [40, 40], friendAfter: [30, 30], enemy: [40, 40, 40], enemyAfter: [0, 35, 40]).rank, .b)
        XCTAssertEqual(predict(friend: [100, 100], friendAfter: [50, 100], enemy: [100, 100], enemyAfter: [40, 100]).rank, .c)
        XCTAssertEqual(predict(friend: [100], friendAfter: [25], enemy: [100], enemyAfter: [100]).rank, .d)
        XCTAssertEqual(predict(friend: [30, 30], friendAfter: [0, 10], enemy: [30, 30], enemyAfter: [30, 30]).rank, .e)
    }

    func testCombinedFleetsAndEscapedShipsAreIncludedCorrectly() {
        let input = BattleRankInput(
            friendlyMain: .init(initialHP: [30, 30], finalHP: [30, 0], escaped: [1]),
            friendlyEscort: .init(initialHP: [20], finalHP: [20]),
            enemyMain: .init(initialHP: [10, 10], finalHP: [0, 0]),
            enemyEscort: .init(initialHP: [10], finalHP: [0])
        )
        XCTAssertEqual(predictor.predict(input).rank, .ss)
    }

    func testUnknownEnemyHPDoesNotForceRank() {
        let result = predictor.predict(.init(
            friendlyMain: .init(initialHP: [30], finalHP: [30]),
            enemyMain: .init(initialHP: [20, 20], finalHP: [0, nil])
        ))
        XCTAssertNil(result.rank)
        XCTAssertEqual(result.confidence, .degraded)
        XCTAssertEqual(result.reasonCodes, [.unknownEnemyHP])
    }

    func testZeroAndEmptyHPDoNotDivideByZero() {
        XCTAssertNil(predict(friend: [], friendAfter: [], enemy: [10], enemyAfter: [0]).rank)
        XCTAssertNil(predict(friend: [0], friendAfter: [0], enemy: [10], enemyAfter: [0]).rank)
    }

    func testLandAirDefenseThresholds() {
        for (after, rank) in [(100, BattleRank.ss), (91, .a), (81, .b), (51, .c), (21, .d), (20, .e)] {
            let result = predictor.predict(.init(
                friendlyMain: .init(initialHP: [100], finalHP: [after]),
                enemyMain: .init(initialHP: [], finalHP: []),
                isLandAirDefense: true
            ))
            XCTAssertEqual(result.rank, rank, "after=\(after)")
        }
    }

    func testResultMergeUsesServerRankAndRecordsBoundedMismatch() {
        let prediction = BattleRankPrediction(
            rank: .s,
            confidence: .exact,
            reasonCodes: [.enemyAnnihilated],
            friendlyDamagePercent: 1,
            enemyDamagePercent: 100
        )
        let data: JSONValue = .object([
            "api_win_rank": .string("A"),
            "api_mvp": .integer(2),
            "api_mvp_combined": .integer(3),
            "api_get_base_exp": .integer(120),
            "api_get_exp": .integer(55),
            "api_get_ship_exp": .array((1...20).map { .integer(Int64($0)) }),
            "api_get_ship": .object([
                "api_ship_id": .integer(501),
                "api_ship_name": .string("Drop")
            ])
        ])
        let merged = BattleResultMerger().merge(data: data, prediction: prediction)
        XCTAssertEqual(merged?.server.rank, .a)
        XCTAssertEqual(merged?.server.mvp, 2)
        XCTAssertEqual(merged?.server.shipExperience.count, 12)
        XCTAssertEqual(merged?.server.drop?.shipID, 501)
        XCTAssertEqual(merged?.diagnostics, ["rank_mismatch:S->A"])
        XCTAssertEqual(merged?.prediction?.rank, .s)
    }

    private func predict(
        friend: [Int?],
        friendAfter: [Int?],
        enemy: [Int?],
        enemyAfter: [Int?]
    ) -> BattleRankPrediction {
        predictor.predict(.init(
            friendlyMain: .init(initialHP: friend, finalHP: friendAfter),
            enemyMain: .init(initialHP: enemy, finalHP: enemyAfter)
        ))
    }
}
