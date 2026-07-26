import XCTest
@testable import GameCore

final class GameDataPipelineTests: XCTestCase {
    func testReplaysStart2AndPortRealStructure() async throws {
        let pipeline = GameDataPipeline()
        let masterEvent = try await pipeline.ingest(endpoint: "/kcsapi/api_start2", response: fixture("api_start2.json"))
        let portEvent = try await pipeline.ingest(endpoint: "https://w00g.kancolle-server.com/kcsapi/api_port/port", response: fixture("api_port.json"))
        let state = await pipeline.state()

        XCTAssertEqual(masterEvent, .masterDataUpdated)
        XCTAssertEqual(portEvent, .portUpdated)
        XCTAssertEqual(state.master.ships[1]?.name, "睦月")
        XCTAssertEqual(state.master.slotItems[42]?.category, 23)
        XCTAssertEqual(state.master.shipTypes[2]?.equipmentTypes[23], 1)
        XCTAssertEqual(state.master.mapAreas[46]?.type, 1)
        XCTAssertEqual(state.master.maps[11]?.mapAreaID, 1)

        XCTAssertEqual(state.fleet.admiral?.nickname, "提督")
        XCTAssertEqual(state.fleet.ships.count, 2)
        XCTAssertEqual(state.fleet.slotItems.count, 2)
        XCTAssertEqual(state.fleet.decks[1]?.shipIDs, [101, 102])
        XCTAssertEqual(state.fleet.decks[2]?.expedition?.missionID, 5)
        XCTAssertEqual(state.fleet.decks[2]?.expedition?.completionTime, 1_893_456_000_000)
        XCTAssertEqual(state.fleet.repairDocks[1]?.shipID, 102)
        XCTAssertTrue(state.fleet.repairDocks[1]?.isOccupied == true)
        XCTAssertFalse(state.fleet.repairDocks[2]?.isOccupied == true)
    }

    func testIncrementalShipDeckSlotItemAndDeckUpdates() async throws {
        let pipeline = GameDataPipeline()
        _ = try await pipeline.ingest(endpoint: "/api_port/port", response: fixture("api_port.json"))

        _ = try await pipeline.ingest(endpoint: "/api_get_member/ship_deck", response: fixture("api_ship_deck.json"))
        var fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(fleet.ships.count, 2, "ship_deck must merge rather than delete unmentioned ships")
        XCTAssertEqual(fleet.ships[101]?.level, 51)
        XCTAssertEqual(fleet.ships[102]?.currentHP, 24)
        XCTAssertEqual(fleet.decks[1]?.name, "出撃艦隊")
        XCTAssertNotNil(fleet.decks[2], "ship_deck must preserve unmentioned decks")

        _ = try await pipeline.ingest(endpoint: "/api_get_member/slot_item", response: fixture("api_slot_item.json"))
        fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(Set(fleet.slotItems.keys), Set([501, 503]))
        XCTAssertEqual(fleet.slotItems[501]?.improvementLevel, 3)
        XCTAssertNil(fleet.slotItems[502])

        _ = try await pipeline.ingest(endpoint: "/api_get_member/deck", response: fixture("api_deck.json"))
        fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(Set(fleet.decks.keys), Set([1, 3]))
        XCTAssertEqual(fleet.decks[1]?.shipIDs, [102, 101])
        XCTAssertEqual(fleet.decks[3]?.expedition?.missionID, 21)
    }

    func testHeavyDamageUsesKcanotifyQuarterHPBoundary() async throws {
        let pipeline = GameDataPipeline()
        _ = try await pipeline.ingest(endpoint: "/api_port/port", response: fixture("api_port.json"))
        var fleet = await pipeline.fleetSnapshot()

        XCTAssertTrue(fleet.ships[101]?.isHeavilyDamaged == true, "5 * 4 <= 40 is taiha")
        XCTAssertFalse(fleet.ships[102]?.isHeavilyDamaged == true)
        XCTAssertEqual(fleet.heavilyDamagedShipIDs(inDeck: 1), [101])
        XCTAssertTrue(fleet.containsHeavyDamage(inDeck: 1))

        _ = try await pipeline.ingest(endpoint: "/api_get_member/ship_deck", response: fixture("api_ship_deck.json"))
        fleet = await pipeline.fleetSnapshot()
        XCTAssertFalse(fleet.containsHeavyDamage(inDeck: 1))
    }

    func testUnknownEndpointAndFieldsAreIgnoredWithoutStateLoss() async throws {
        let pipeline = GameDataPipeline()
        _ = try await pipeline.ingest(endpoint: "/api_start2", response: fixture("api_start2.json"))
        let before = await pipeline.state()
        let event = try await pipeline.ingest(
            endpoint: "/kcsapi/api_future/new_endpoint",
            response: Data("svdata={\"api_result\":1,\"api_data\":{\"new_field\":true}}".utf8)
        )
        let after = await pipeline.state()

        XCTAssertEqual(event, .ignored(endpoint: "/api_future/new_endpoint"))
        XCTAssertEqual(after, before)
    }

    func testBadJSONDoesNotMutateStateAndAPIFailureIsReported() async throws {
        let pipeline = GameDataPipeline()
        _ = try await pipeline.ingest(endpoint: "/api_port/port", response: fixture("api_port.json"))
        let before = await pipeline.state()

        do {
            _ = try await pipeline.ingest(endpoint: "/api_port/port", response: Data("svdata={bad".utf8))
            XCTFail("Expected invalid JSON")
        } catch {
            XCTAssertEqual(error as? APIEnvelopeParser.ParseError, .invalidJSON)
        }
        let afterBadJSON = await pipeline.state()
        XCTAssertEqual(afterBadJSON, before)

        let event = try await pipeline.ingest(
            endpoint: "/api_port/port",
            response: Data("svdata={\"api_result\":201,\"api_result_msg\":\"maintenance\",\"api_data\":{}}".utf8)
        )
        XCTAssertEqual(event, .apiFailure(endpoint: "/api_port/port", result: 201, message: "maintenance"))
        let afterFailure = await pipeline.state()
        XCTAssertEqual(afterFailure, before)
    }

    func testRequireInfoEquipmentBaselineAndReset() async throws {
        let pipeline = GameDataPipeline()
        let payload = Data("svdata={\"api_result\":1,\"api_data\":{\"api_slot_item\":[{\"api_id\":900,\"api_slotitem_id\":10,\"api_level\":0,\"api_alv\":0,\"api_locked\":1}],\"api_kdock\":[]}}".utf8)
        let event = try await pipeline.ingest(endpoint: "/api_get_member/require_info", response: payload)
        var state = await pipeline.state()
        XCTAssertEqual(event, .slotItemsUpdated)
        XCTAssertEqual(state.fleet.slotItems[900]?.masterSlotItemID, 10)

        await pipeline.reset()
        state = await pipeline.state()
        XCTAssertTrue(state.master.ships.isEmpty)
        XCTAssertTrue(state.fleet.ships.isEmpty)
        XCTAssertTrue(state.fleet.slotItems.isEmpty)
    }

    func testAlreadyParsedEnvelopeUsesSameMutationAndDeduplicationPath() async throws {
        let pipeline = GameDataPipeline()
        let envelope = try APIEnvelopeParser().parse(
            endpoint: "/api_port/port",
            response: fixture("api_port.json")
        )
        let first = await pipeline.ingest(envelope: envelope, eventID: "parsed-port")
        let duplicate = await pipeline.ingest(envelope: envelope, eventID: "parsed-port")
        let state = await pipeline.state()

        XCTAssertEqual(first, .portUpdated)
        XCTAssertEqual(duplicate, .duplicate(eventID: "parsed-port"))
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.fleet.decks[1]?.shipIDs, [101, 102])
    }

    private func fixture(_ name: String) -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/P2", isDirectory: true)
        return try! Data(contentsOf: directory.appendingPathComponent(name))
    }
}
