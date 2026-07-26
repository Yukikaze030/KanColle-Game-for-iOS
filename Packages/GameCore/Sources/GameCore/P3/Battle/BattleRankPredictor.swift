import Foundation

public enum BattleRank: String, Codable, CaseIterable, Sendable {
    case ss = "SS"
    case s = "S"
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"
}

public enum BattleRankConfidence: String, Codable, Sendable {
    case exact
    case degraded
    case unavailable
}

public enum BattleRankReason: String, Codable, Sendable {
    case noFriendlyDamage
    case enemyAnnihilated
    case enemySeventyPercentSunk
    case enemyFlagshipSunk
    case favorableDamageRatio
    case marginalDamageRatio
    case singleShipHeavyDamage
    case onlyOneFriendlySurvivor
    case fallback
    case landAirDefense
    case unknownFriendlyHP
    case unknownEnemyHP
    case emptyFleet
    case zeroInitialHP
}

public struct BattleRankFleetInput: Equatable, Sendable {
    public var initialHP: [Int?]
    public var finalHP: [Int?]
    /// Zero-based positions omitted from rank calculation because they retreated.
    public var escaped: Set<Int>

    public init(initialHP: [Int?], finalHP: [Int?], escaped: Set<Int> = []) {
        self.initialHP = initialHP
        self.finalHP = finalHP
        self.escaped = escaped
    }
}

public struct BattleRankInput: Equatable, Sendable {
    public var friendlyMain: BattleRankFleetInput
    public var friendlyEscort: BattleRankFleetInput?
    public var enemyMain: BattleRankFleetInput
    public var enemyEscort: BattleRankFleetInput?
    public var isLandAirDefense: Bool
    public var isPractice: Bool

    public init(
        friendlyMain: BattleRankFleetInput,
        friendlyEscort: BattleRankFleetInput? = nil,
        enemyMain: BattleRankFleetInput,
        enemyEscort: BattleRankFleetInput? = nil,
        isLandAirDefense: Bool = false,
        isPractice: Bool = false
    ) {
        self.friendlyMain = friendlyMain
        self.friendlyEscort = friendlyEscort
        self.enemyMain = enemyMain
        self.enemyEscort = enemyEscort
        self.isLandAirDefense = isLandAirDefense
        self.isPractice = isPractice
    }
}

public struct BattleRankPrediction: Codable, Equatable, Sendable {
    public let rank: BattleRank?
    public let confidence: BattleRankConfidence
    public let reasonCodes: [BattleRankReason]
    public let friendlyDamagePercent: Int?
    public let enemyDamagePercent: Int?

    public init(
        rank: BattleRank?,
        confidence: BattleRankConfidence,
        reasonCodes: [BattleRankReason],
        friendlyDamagePercent: Int?,
        enemyDamagePercent: Int?
    ) {
        self.rank = rank
        self.confidence = confidence
        self.reasonCodes = reasonCodes
        self.friendlyDamagePercent = friendlyDamagePercent
        self.enemyDamagePercent = enemyDamagePercent
    }
}

public struct BattleRankPredictor: Sendable {
    public init() {}

    /// Mirrors Kcanotify's `calculateRank` and `calculateLdaRank`, while refusing
    /// to manufacture an exact result when the server masks HP as "N".
    public func predict(_ input: BattleRankInput) -> BattleRankPrediction {
        let friendly = aggregate(input.friendlyMain, input.friendlyEscort)
        guard friendly.count > 0 else {
            return unavailable(.emptyFleet)
        }
        guard !friendly.hasUnknown else {
            return unavailable(.unknownFriendlyHP)
        }
        guard let friendlyDamage = damagePercent(friendly) else {
            return unavailable(.zeroInitialHP)
        }

        if input.isLandAirDefense {
            let rank: BattleRank
            let reason: BattleRankReason
            switch friendlyDamage {
            case 0:
                rank = .ss
                reason = .noFriendlyDamage
            case ..<10:
                rank = .a
                reason = .landAirDefense
            case ..<20:
                rank = .b
                reason = .landAirDefense
            case ..<50:
                rank = .c
                reason = .landAirDefense
            case ..<80:
                rank = .d
                reason = .landAirDefense
            default:
                rank = .e
                reason = .landAirDefense
            }
            return .init(
                rank: rank,
                confidence: .exact,
                reasonCodes: [reason],
                friendlyDamagePercent: friendlyDamage,
                enemyDamagePercent: nil
            )
        }

        let enemy = aggregate(input.enemyMain, input.enemyEscort)
        guard enemy.count > 0 else {
            return unavailable(.emptyFleet, friendlyDamage: friendlyDamage)
        }
        // Enemy HP can be masked during some battles. Counting only visible ships
        // changes both the denominator and flagship condition, so expose no rank.
        guard !enemy.hasUnknown else {
            return .init(
                rank: nil,
                confidence: .degraded,
                reasonCodes: [.unknownEnemyHP],
                friendlyDamagePercent: friendlyDamage,
                enemyDamagePercent: damagePercent(enemy)
            )
        }
        guard let enemyDamage = damagePercent(enemy) else {
            return unavailable(.zeroInitialHP, friendlyDamage: friendlyDamage)
        }

        let rankAndReason: (BattleRank, BattleRankReason)
        if friendly.sunk == 0, enemy.sunk == enemy.count {
            rankAndReason = friendly.finalSum >= friendly.initialSum
                ? (.ss, .noFriendlyDamage)
                : (.s, .enemyAnnihilated)
        } else if friendly.sunk == 0,
                  enemy.count > 1,
                  enemy.sunk >= Int(floor(0.7 * Double(enemy.count))) {
            rankAndReason = (.a, .enemySeventyPercentSunk)
        } else if enemy.flagshipSunk, friendly.sunk < enemy.sunk {
            rankAndReason = (.b, .enemyFlagshipSunk)
        } else if friendly.count == 1,
                  friendly.firstInitial.map({ friendly.firstFinal * 4 <= $0 }) == true {
            rankAndReason = (.d, .singleShipHeavyDamage)
        } else if enemyDamage * 2 > friendlyDamage * 5 {
            rankAndReason = (.b, .favorableDamageRatio)
        } else if enemyDamage * 10 > friendlyDamage * 9 {
            rankAndReason = (.c, .marginalDamageRatio)
        } else if friendly.sunk > 0, friendly.count - friendly.sunk == 1 {
            rankAndReason = (.e, .onlyOneFriendlySurvivor)
        } else {
            rankAndReason = (.d, .fallback)
        }

        return .init(
            rank: rankAndReason.0,
            confidence: .exact,
            reasonCodes: [rankAndReason.1],
            friendlyDamagePercent: friendlyDamage,
            enemyDamagePercent: enemyDamage
        )
    }

    private func unavailable(
        _ reason: BattleRankReason,
        friendlyDamage: Int? = nil
    ) -> BattleRankPrediction {
        .init(
            rank: nil,
            confidence: .unavailable,
            reasonCodes: [reason],
            friendlyDamagePercent: friendlyDamage,
            enemyDamagePercent: nil
        )
    }

    private struct Aggregate {
        var count = 0
        var sunk = 0
        var initialSum = 0
        var finalSum = 0
        var hasUnknown = false
        var flagshipSunk = false
        var firstInitial: Int?
        var firstFinal = 0
    }

    private func aggregate(
        _ main: BattleRankFleetInput,
        _ escort: BattleRankFleetInput?
    ) -> Aggregate {
        var result = Aggregate()
        append(main, isMain: true, to: &result)
        if let escort {
            append(escort, isMain: false, to: &result)
        }
        return result
    }

    private func append(
        _ fleet: BattleRankFleetInput,
        isMain: Bool,
        to result: inout Aggregate
    ) {
        let count = max(fleet.initialHP.count, fleet.finalHP.count)
        for index in 0..<count where !fleet.escaped.contains(index) {
            let initial = index < fleet.initialHP.count ? fleet.initialHP[index] : nil
            let final = index < fleet.finalHP.count ? fleet.finalHP[index] : nil
            guard let initial, let final else {
                result.hasUnknown = true
                continue
            }
            result.count += 1
            result.initialSum += max(0, initial)
            result.finalSum += max(0, final)
            if final <= 0 { result.sunk += 1 }
            if isMain, index == 0 {
                result.flagshipSunk = final <= 0
            }
            if result.count == 1 {
                result.firstInitial = initial
                result.firstFinal = final
            }
        }
    }

    private func damagePercent(_ aggregate: Aggregate) -> Int? {
        guard aggregate.initialSum > 0 else { return nil }
        return max(0, aggregate.initialSum - aggregate.finalSum) * 100 / aggregate.initialSum
    }
}

public struct BattleDropSummary: Codable, Equatable, Sendable {
    public let shipID: Int?
    public let shipName: String?
    public let itemID: Int?
    public let itemName: String?
}

public struct BattleServerResult: Codable, Equatable, Sendable {
    public let rank: BattleRank?
    public let rawRank: String?
    public let mvp: Int?
    public let combinedMVP: Int?
    public let baseExperience: Int?
    public let memberExperience: Int?
    public let shipExperience: [Int]
    public let drop: BattleDropSummary?
}

public struct BattleResultMerge: Codable, Equatable, Sendable {
    public let prediction: BattleRankPrediction?
    public let server: BattleServerResult
    public let diagnostics: [String]
}

public struct BattleResultMerger: Sendable {
    public init() {}

    public func merge(
        data: JSONValue,
        prediction: BattleRankPrediction?
    ) -> BattleResultMerge? {
        guard let object = data.objectValue else { return nil }
        let rawRank = object["api_win_rank"]?.stringValue
        let serverRank = rawRank.flatMap(BattleRank.init(rawValue:))
        let shipExperience = object["api_get_ship_exp"]?.arrayValue?.compactMap(\.intValue) ?? []

        var drop: BattleDropSummary?
        let ship = object["api_get_ship"]?.objectValue
        let item = object["api_get_useitem"]?.objectValue
        if ship != nil || item != nil {
            drop = .init(
                shipID: ship?.int("api_ship_id"),
                shipName: ship?["api_ship_name"]?.stringValue,
                itemID: item?.int("api_useitem_id"),
                itemName: item?["api_useitem_name"]?.stringValue
            )
        }

        let server = BattleServerResult(
            rank: serverRank,
            rawRank: rawRank.map { String($0.prefix(8)) },
            mvp: object.int("api_mvp"),
            combinedMVP: object.int("api_mvp_combined"),
            baseExperience: object.int("api_get_base_exp"),
            memberExperience: object.int("api_get_exp"),
            shipExperience: Array(shipExperience.prefix(12)),
            drop: drop
        )
        var diagnostics: [String] = []
        if let predicted = prediction?.rank, let serverRank, predicted != serverRank {
            diagnostics.append("rank_mismatch:\(predicted.rawValue)->\(serverRank.rawValue)")
        }
        if rawRank != nil, serverRank == nil {
            diagnostics.append("unknown_server_rank")
        }
        return .init(prediction: prediction, server: server, diagnostics: diagnostics)
    }
}
