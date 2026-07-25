import XCTest
@testable import GameCore

final class IncrementalStateReducerTests: XCTestCase {
    func testFullOrderedSequenceHasStableGoldenStateAndRevision() async throws {
        let pipeline = GameDataPipeline()
        _ = try await loadPort(into: pipeline)

        let change = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: form("api_id=2&api_ship_idx=0&api_ship_id=102"),
            eventID: "change-1"
        )
        let charge = try await pipeline.ingest(
            endpoint: "/api_req_hokyu/charge",
            response: fixture("charge.json"),
            eventID: "charge-1"
        )
        _ = try await pipeline.ingest(
            endpoint: "/api_req_nyukyo/start",
            response: fixture("nyukyo_start.json"),
            requestBody: form("api_ndock_id=2&api_ship_id=101&api_highspeed=0"),
            eventID: "dock-1"
        )
        _ = try await pipeline.ingest(
            endpoint: "/api_req_nyukyo/speedchange",
            response: fixture("nyukyo_speedchange.json"),
            requestBody: form("api_ndock_id=2"),
            eventID: "bucket-1"
        )
        _ = try await pipeline.ingest(
            endpoint: "/api_req_mission/result",
            response: fixture("hensei_change.json"),
            requestBody: form("api_deck_id=2"),
            eventID: "mission-result-1"
        )

        let state = await pipeline.state()
        XCTAssertEqual(change, .incrementalUpdated(endpoint: "/api_req_hensei/change", warnings: []))
        guard case let .incrementalUpdated(_, warnings) = charge else {
            return XCTFail("Expected charge update")
        }
        XCTAssertEqual(warnings, ["charge references unknown ship 999"])
        XCTAssertEqual(state.revision, 6)
        XCTAssertEqual(state.fleet.decks[1]?.shipIDs, [101])
        XCTAssertEqual(state.fleet.decks[2]?.shipIDs, [102])
        XCTAssertNil(state.fleet.decks[2]?.expedition)
        XCTAssertEqual(state.fleet.ships[101]?.fuel, 15)
        XCTAssertEqual(state.fleet.ships[101]?.ammunition, 20)
        XCTAssertEqual(state.fleet.ships[101]?.aircraftCounts, [3, 0])
        XCTAssertEqual(state.fleet.ships[101]?.currentHP, 40)
        XCTAssertFalse(state.fleet.repairDocks[2]?.isOccupied == true)
    }

    func testEventIDDeDuplicatesWithinLRUAndResetClearsIt() async throws {
        let pipeline = GameDataPipeline(deduplicationCapacity: 2)
        _ = try await loadPort(into: pipeline)
        let body = form("api_id=1&api_ship_idx=1&api_ship_id=-1")

        let first = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: body,
            eventID: "same"
        )
        let duplicate = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: body,
            eventID: "same"
        )

        XCTAssertEqual(first, .incrementalUpdated(endpoint: "/api_req_hensei/change", warnings: []))
        XCTAssertEqual(duplicate, .duplicate(eventID: "same"))
        var state = await pipeline.state()
        XCTAssertEqual(state.revision, 2)
        XCTAssertEqual(state.fleet.decks[1]?.shipIDs, [101])

        await pipeline.reset()
        _ = try await loadPort(into: pipeline)
        let afterReset = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: body,
            eventID: "same"
        )
        XCTAssertNotEqual(afterReset, .duplicate(eventID: "same"))
        state = await pipeline.state()
        XCTAssertEqual(state.revision, 2)
    }

    func testMalformedRequestsWarnWithoutRevisionOrCollateralMutation() async throws {
        let pipeline = GameDataPipeline()
        _ = try await loadPort(into: pipeline)
        let baseline = await pipeline.state()

        let missing = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: form("api_id=1")
        )
        let outOfRange = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: form("api_id=1&api_ship_idx=99&api_ship_id=-1")
        )
        let unknownShip = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: form("api_id=1&api_ship_idx=1&api_ship_id=999")
        )
        let unknownDock = try await pipeline.ingest(
            endpoint: "/api_req_nyukyo/speedchange",
            response: fixture("nyukyo_speedchange.json"),
            requestBody: form("api_ndock_id=99")
        )

        for event in [missing, outOfRange, unknownShip, unknownDock] {
            guard case let .incrementalUpdated(_, warnings) = event else {
                return XCTFail("Malformed recognized endpoint must report warnings")
            }
            XCTAssertFalse(warnings.isEmpty)
        }
        let after = await pipeline.state()
        XCTAssertEqual(after, baseline)
    }

    func testUnknownEndpointIsIgnoredWithoutRevision() async throws {
        let pipeline = GameDataPipeline()
        _ = try await loadPort(into: pipeline)
        let before = await pipeline.state()
        let event = try await pipeline.ingest(
            endpoint: "/api_future/incremental",
            response: Data("svdata={\"api_result\":1,\"api_data\":{\"x\":1}}".utf8),
            eventID: "future-1"
        )

        XCTAssertEqual(event, .ignored(endpoint: "/api_future/incremental"))
        let after = await pipeline.state()
        XCTAssertEqual(after, before)
    }

    func testFullAndPartialCollectionReducersPreserveIntendedState() async throws {
        let pipeline = GameDataPipeline()
        _ = try await loadPort(into: pipeline)

        _ = try await pipeline.ingest(
            endpoint: "/api_get_member/ship_deck",
            response: fixture("ship_deck.json")
        )
        var fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(fleet.ships[101]?.level, 52)
        XCTAssertEqual(fleet.ships[101]?.currentHP, 9)
        XCTAssertEqual(fleet.ships[101]?.fuel, 12)
        XCTAssertNotNil(fleet.ships[102], "partial ship updates must not delete unreturned ships")
        XCTAssertEqual(fleet.decks[1]?.name, "更新第一艦隊")
        XCTAssertNotNil(fleet.decks[2], "partial deck updates must not delete unreturned decks")

        _ = try await pipeline.ingest(
            endpoint: "/api_get_member/deck",
            response: fixture("deck_expedition.json")
        )
        fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(Set(fleet.decks.keys), Set([1, 2]))
        XCTAssertEqual(fleet.decks[2]?.expedition?.missionID, 21)

        _ = try await pipeline.ingest(
            endpoint: "/api_get_member/slot_item",
            response: baselineFixture("api_slot_item.json")
        )
        fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(Set(fleet.slotItems.keys), Set([501, 503]))
    }

    func testPresetDockMissionReturnAndConditionReducers() async throws {
        let pipeline = GameDataPipeline()
        _ = try await loadPort(into: pipeline)

        _ = try await pipeline.ingest(
            endpoint: "/api_req_hensei/preset_select",
            response: fixture("hensei_preset.json"),
            requestBody: form("api_deck_id=2&api_preset_no=3")
        )
        var fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(fleet.decks[1]?.shipIDs, [])
        XCTAssertEqual(fleet.decks[2]?.shipIDs, [102, 101])

        // Restore the authoritative port state before testing expedition and morale APIs.
        _ = try await loadPort(into: pipeline)
        _ = try await pipeline.ingest(
            endpoint: "/api_req_mission/return_instruction",
            response: fixture("mission_return.json"),
            requestBody: form("api_deck_id=2")
        )
        _ = try await pipeline.ingest(
            endpoint: "/api_req_member/itemuse_cond",
            response: fixture("itemuse_cond.json"),
            requestBody: form("api_deck_id=1")
        )
        _ = try await pipeline.ingest(
            endpoint: "/api_get_member/ndock",
            response: fixture("ndock_active.json")
        )

        fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(fleet.decks[2]?.expedition?.status, 2)
        XCTAssertEqual(fleet.decks[2]?.expedition?.completionTime, 1_893_456_123_456)
        XCTAssertEqual(fleet.ships[101]?.condition, 55)
        XCTAssertEqual(fleet.ships[102]?.condition, 54)
        XCTAssertEqual(fleet.repairDocks.count, 4)
        XCTAssertEqual(fleet.repairDocks[2]?.shipID, 101)
    }

    func testCompositionClearAllAndCrossFleetSwapAreConsistent() async throws {
        let pipeline = GameDataPipeline()
        _ = try await loadPort(into: pipeline)

        _ = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: form("api_id=2&api_ship_idx=0&api_ship_id=102")
        )
        _ = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: form("api_id=1&api_ship_idx=0&api_ship_id=102")
        )
        var fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(fleet.decks[1]?.shipIDs, [102])
        XCTAssertEqual(fleet.decks[2]?.shipIDs, [101])

        _ = try await pipeline.ingest(
            endpoint: "/api_req_hensei/change",
            response: fixture("hensei_change.json"),
            requestBody: form("api_id=2&api_ship_idx=0&api_ship_id=-2")
        )
        fleet = await pipeline.fleetSnapshot()
        XCTAssertEqual(fleet.decks[2]?.shipIDs, [101])
        let allAssigned = fleet.decks.values.flatMap(\.shipIDs)
        XCTAssertEqual(Set(allAssigned).count, allAssigned.count, "a ship may belong to at most one fleet")
    }

    private func loadPort(into pipeline: GameDataPipeline) async throws -> GameDataPipelineEvent {
        try await pipeline.ingest(endpoint: "/api_port/port", response: baselineFixture("api_port.json"))
    }

    private func form(_ value: String) -> Data {
        Data(value.utf8)
    }

    private func fixture(_ name: String) -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        return try! Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func baselineFixture(_ name: String) -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/P2", isDirectory: true)
        return try! Data(contentsOf: directory.appendingPathComponent(name))
    }
}
