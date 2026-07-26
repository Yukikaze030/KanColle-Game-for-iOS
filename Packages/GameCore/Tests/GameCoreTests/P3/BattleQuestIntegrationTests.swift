import XCTest
@testable import GameCore

final class BattleQuestIntegrationTests: XCTestCase {
    func testMapBattleResultReplaySharesEnvelopeAndEventIDs() async throws {
        let parser = APIEnvelopeParser()
        let pipeline = GameDataPipeline()
        var battle = BattleSessionReducer()
        var quests = QuestProgressReducer(definitions: [
            201: .init(id: 201, resetKind: .daily, conditionTargets: [1]),
            210: .init(id: 210, resetKind: .daily, conditionTargets: [10])
        ])
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var questSnapshot = QuestListSnapshot(
            items: [:],
            tracking: [
                201: .init(questID: 201, isActive: true, counters: [0], startedAt: started, precision: .exact),
                210: .init(questID: 210, isActive: true, counters: [0], startedAt: started, precision: .exact)
            ]
        )

        let map = try parser.parse(
            endpoint: "/api_req_map/start",
            response: Data(#"svdata={"api_result":1,"api_data":{"api_no":4,"api_bosscell_no":4}}"#.utf8),
            requestBody: Data("api_deck_id=1&api_maparea_id=1&api_mapinfo_no=1".utf8)
        )
        let mapPipelineEvent = await pipeline.ingest(envelope: map, eventID: "map")
        XCTAssertEqual(mapPipelineEvent, .ignored(endpoint: "/api_req_map/start"))
        let position = BattlePhaseDecoder().mapPosition(from: map)

        let day = try parser.parse(
            endpoint: "/api_req_sortie/battle",
            response: Data(#"svdata={"api_result":1,"api_data":{"api_f_maxhps":[-1,30],"api_f_nowhps":[-1,30],"api_e_maxhps":[-1,20],"api_e_nowhps":[-1,20],"api_ship_ke":[501],"api_hougeki1":{"api_at_eflag":[0],"api_df_list":[[0]],"api_damage":[[20]]}}}"#.utf8)
        )
        guard case let .started(daySnapshot, _) = battle.reduce(
            envelope: day,
            eventID: "day",
            friendlyMainShipIDs: [101],
            map: position
        ) else { return XCTFail("battle did not start") }
        XCTAssertEqual(daySnapshot.enemyMain.ships[0].currentHP, 0)

        let result = try parser.parse(
            endpoint: "/api_req_sortie/battleresult",
            response: Data(#"svdata={"api_result":1,"api_data":{"api_win_rank":"S","api_mvp":1}}"#.utf8)
        )
        guard case let .completed(completed) = battle.reduce(envelope: result, eventID: "result") else {
            return XCTFail("battle did not complete")
        }
        let prediction = BattleRankPredictor().predict(.init(
            friendlyMain: .init(initialHP: [30], finalHP: [30]),
            enemyMain: .init(initialHP: [20], finalHP: [0])
        ))
        let merged = try XCTUnwrap(BattleResultMerger().merge(data: try XCTUnwrap(result.data), prediction: prediction))
        XCTAssertEqual(merged.server.rank, .s)
        XCTAssertEqual(completed.revision, 2)

        let conditional = BattleCompletedQuestEvent(
            snapshot: completed,
            rank: merged.server.rank!,
            masterShipTypes: [501: 2]
        )
        XCTAssertEqual(
            quests.reduce(
                .battleCompleted(conditional),
                eventID: "result#conditional",
                occurredAt: started.addingTimeInterval(60),
                snapshot: &questSnapshot
            ),
            .applied(questIDs: [201, 210])
        )
        XCTAssertEqual(questSnapshot.tracking[201]?.counters, [1])
        XCTAssertEqual(questSnapshot.tracking[210]?.counters, [1])

        XCTAssertEqual(
            quests.reduce(
                .battleCompleted(conditional),
                eventID: "result#conditional",
                occurredAt: started.addingTimeInterval(60),
                snapshot: &questSnapshot
            ),
            .duplicate(eventID: "result#conditional")
        )
        XCTAssertEqual(battle.reduce(envelope: result, eventID: "result"), .duplicate(eventID: "result"))
    }
}
