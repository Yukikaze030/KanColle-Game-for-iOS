import Foundation

public struct BattleEndpoint: Codable, Hashable, Sendable {
    public enum Known: String, Codable, CaseIterable, Sendable {
        case mapStart = "/api_req_map/start"
        case mapNext = "/api_req_map/next"
        case mapRank = "/api_req_map/select_eventmap_rank"
        case sortieGoback = "/api_req_sortie/goback_port"
        case combinedGoback = "/api_req_combined_battle/goback_port"
        case sortieBattle = "/api_req_sortie/battle"
        case sortieAirBattle = "/api_req_sortie/airbattle"
        case sortieLandAirBattle = "/api_req_sortie/ld_airbattle"
        case sortieLandShooting = "/api_req_sortie/ld_shooting"
        case sortieNightToDay = "/api_req_sortie/night_to_day"
        case midnightBattle = "/api_req_battle_midnight/battle"
        case specialMidnight = "/api_req_battle_midnight/sp_midnight"
        case sortieResult = "/api_req_sortie/battleresult"
        case practiceBattle = "/api_req_practice/battle"
        case practiceMidnight = "/api_req_practice/midnight_battle"
        case practiceResult = "/api_req_practice/battle_result"
        case combinedBattle = "/api_req_combined_battle/battle"
        case combinedWater = "/api_req_combined_battle/battle_water"
        case combinedAirBattle = "/api_req_combined_battle/airbattle"
        case combinedLandAirBattle = "/api_req_combined_battle/ld_airbattle"
        case combinedLandShooting = "/api_req_combined_battle/ld_shooting"
        case enemyCombinedBattle = "/api_req_combined_battle/ec_battle"
        case eachBattle = "/api_req_combined_battle/each_battle"
        case eachWater = "/api_req_combined_battle/each_battle_water"
        case enemyCombinedNightToDay = "/api_req_combined_battle/ec_night_to_day"
        case combinedMidnight = "/api_req_combined_battle/midnight_battle"
        case combinedSpecialMidnight = "/api_req_combined_battle/sp_midnight"
        case enemyCombinedMidnight = "/api_req_combined_battle/ec_midnight_battle"
        case combinedResult = "/api_req_combined_battle/battleresult"
    }

    public let path: String
    public var known: Known? { Known(rawValue: path) }

    public init(_ rawPath: String) {
        path = APIEnvelopeParser.normalizeEndpoint(rawPath)
    }

    public var initializesSession: Bool {
        switch known {
        case .sortieBattle, .sortieAirBattle, .sortieLandAirBattle, .sortieLandShooting,
             .sortieNightToDay, .specialMidnight, .practiceBattle,
             .combinedBattle, .combinedWater, .combinedAirBattle,
             .combinedLandAirBattle, .combinedLandShooting, .enemyCombinedBattle,
             .eachBattle, .eachWater, .enemyCombinedNightToDay,
             .combinedSpecialMidnight:
            true
        default:
            false
        }
    }

    public var continuesSession: Bool {
        switch known {
        case .midnightBattle, .practiceMidnight, .combinedMidnight, .enemyCombinedMidnight:
            true
        default:
            false
        }
    }

    public var isResult: Bool {
        switch known {
        case .sortieResult, .practiceResult, .combinedResult: true
        default: false
        }
    }

    public var isPractice: Bool {
        switch known {
        case .practiceBattle, .practiceMidnight, .practiceResult: true
        default: false
        }
    }

    public var usesFriendlyCombinedFleet: Bool {
        path.hasPrefix("/api_req_combined_battle/")
    }
}
