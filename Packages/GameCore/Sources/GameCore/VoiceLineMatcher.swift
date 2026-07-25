import Foundation

public struct SubtitleMatch: Equatable, Sendable {
    public let text: String
    public let delayMilliseconds: Int
    public let durationMilliseconds: Int
    public let extraDelayMilliseconds: Int64
    public let shipID: String
    public let voiceLine: String

    public init(
        text: String,
        delayMilliseconds: Int,
        durationMilliseconds: Int,
        extraDelayMilliseconds: Int64 = 0,
        shipID: String,
        voiceLine: String
    ) {
        self.text = text
        self.delayMilliseconds = delayMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.extraDelayMilliseconds = extraDelayMilliseconds
        self.shipID = shipID
        self.voiceLine = voiceLine
    }
}

/// Ports GotoBrowser's KC3/KCWiki voice filename lookup. The matcher is kept
/// independent from networking so api_start2 data and downloaded JSON can be
/// replaced atomically by the caller.
public final class VoiceLineMatcher: @unchecked Sendable {
    public enum CatalogError: Error, Equatable {
        case invalidJSONObject
    }

    public static let voiceDiffs = [
        2475, 6547, 1471, 8691, 7847, 3595, 1767, 3311, 2507,
        9651, 5321, 4473, 7117, 5947, 9489, 2669, 8741, 6149,
        1301, 7297, 2975, 6413, 8391, 9705, 2243, 2091, 4231,
        3107, 9499, 4205, 6013, 3393, 6401, 6985, 3683, 9447,
        3287, 5181, 7587, 9353, 2135, 4947, 5405, 5223, 9457,
        5767, 9265, 8191, 3927, 3061, 2805, 3273, 7331
    ]

    private static let specialDiffs = [1555: 1, 3347: 2]
    private static let specialShipVoices = [
        "432": ["917": "917", "918": "918"],
        "353": ["917": "917", "918": "918"]
    ]

    private let lock = NSLock()
    private var filenameToShipID: [String: String]
    private var previousShipByID: [String: String]
    private var quoteLabels: [String: String]
    private var quoteSizes: [String: Any]
    private var seasonalQuoteSizes: [String: Any]
    private var kc3Quotes: [String: Any]
    private var kcwikiQuotes: [String: Any]
    private var voiceDiffCache: [String: [String: Int]] = [:]
    private var baseMillisVoiceLine = 3_000
    private var extraMillisPerCharacter = 0
    private let now: () -> Date
    private let calendar: Calendar

    public init(
        filenameToShipID: [String: String] = [:],
        previousShipByID: [String: String] = [:],
        quoteLabels: [String: String] = [:],
        quoteSizes: [String: Any] = [:],
        seasonalQuoteSizes: [String: Any] = [:],
        kc3Quotes: [String: Any] = [:],
        kcwikiQuotes: [String: Any] = [:],
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.filenameToShipID = filenameToShipID
        self.previousShipByID = previousShipByID
        self.quoteLabels = quoteLabels
        self.quoteSizes = quoteSizes
        self.seasonalQuoteSizes = seasonalQuoteSizes
        self.kc3Quotes = kc3Quotes
        self.kcwikiQuotes = kcwikiQuotes
        self.calendar = calendar
        self.now = now
        updateTiming(from: kc3Quotes)
    }

    public convenience init(
        filenameToShipID: [String: String] = [:],
        previousShipByID: [String: String] = [:],
        quoteLabelData: Data,
        quoteSizeData: Data? = nil,
        kc3QuoteData: Data? = nil,
        kcwikiQuoteData: Data? = nil,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) throws {
        let labelObject = try Self.object(from: quoteLabelData)
        let labels = labelObject.compactMapValues { $0 as? String }
        let seasonal = labelObject["specialQuotesSizes"] as? [String: Any] ?? [:]
        let sizes = try quoteSizeData.map(Self.object(from:)) ?? [:]
        let kc3 = try kc3QuoteData.map(Self.object(from:)) ?? [:]
        let wiki = try kcwikiQuoteData.map(Self.object(from:)) ?? [:]
        self.init(
            filenameToShipID: filenameToShipID,
            previousShipByID: previousShipByID,
            quoteLabels: labels,
            quoteSizes: sizes,
            seasonalQuoteSizes: seasonal,
            kc3Quotes: kc3,
            kcwikiQuotes: wiki,
            calendar: calendar,
            now: now
        )
    }

    /// Builds both filename and remodel maps from api_start2 master arrays.
    /// Remodel exclusions mirror GotoBrowser (624, 646 and 650).
    public func loadMasterData(shipGraphs: [[String: Any]], ships: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        filenameToShipID.removeAll(keepingCapacity: true)
        for graph in shipGraphs {
            guard let id = Self.stringValue(graph["api_id"]),
                  let filename = Self.stringValue(graph["api_filename"])
            else { continue }
            filenameToShipID[filename] = id
        }

        previousShipByID.removeAll(keepingCapacity: true)
        var checked = Set<String>()
        for ship in ships.sorted(by: {
            (Self.intValue($0["api_id"]) ?? 0) < (Self.intValue($1["api_id"]) ?? 0)
        }) {
            guard let id = Self.stringValue(ship["api_id"]),
                  let after = Self.stringValue(ship["api_aftershipid"]),
                  after != "0", !["624", "646", "650"].contains(id),
                  !checked.contains("\(id)_\(after)")
            else { continue }
            previousShipByID[after] = id
            checked.insert("\(after)_\(id)")
        }
        voiceDiffCache.removeAll()
    }

    public func voiceLine(shipID: String, filename: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return voiceLineUnlocked(shipID: shipID, filename: filename)
    }

    public func matchKC3(
        url: String,
        path: String,
        voiceSize: String,
        month: Int? = nil
    ) -> SubtitleMatch? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = resolveRequest(url: url, path: path) else { return nil }
        let selectedMonth = month ?? calendar.component(.month, from: now())
        guard let found = kc3Quote(
            shipID: request.shipID,
            voiceLine: request.voiceLine,
            voiceSize: voiceSize,
            month: selectedMonth,
            remaining: 9
        ) else { return nil }
        let duration = baseMillisVoiceLine
            + extraMillisPerCharacter * found.text.count
        return SubtitleMatch(
            text: found.text,
            delayMilliseconds: found.delay,
            durationMilliseconds: duration,
            extraDelayMilliseconds: hourlyDelay(for: request.voiceLine),
            shipID: request.shipID,
            voiceLine: request.voiceLine
        )
    }

    public func matchKCWiki(url: String, path: String) -> SubtitleMatch? {
        lock.lock()
        defer { lock.unlock() }
        guard !url.contains("/voice/titlecall_"),
              let request = resolveRequest(url: url, path: path),
              let text = wikiQuote(
                  shipID: request.shipID,
                  voiceLine: request.voiceLine,
                  remaining: 9
              )
        else { return nil }
        return SubtitleMatch(
            text: text,
            delayMilliseconds: 0,
            durationMilliseconds: 2_000 + 250 * text.count,
            extraDelayMilliseconds: hourlyDelay(for: request.voiceLine),
            shipID: request.shipID,
            voiceLine: request.voiceLine
        )
    }

    public static func computeVoiceDiff(shipID: String, filename: String) -> Int? {
        guard let ship = Int(shipID), let file = Int(filename) else { return nil }
        let divisor = 17 * (ship + 7)
        guard divisor != 0 else { return nil }
        let remainder = file - 100_000
        if file > 53 && remainder < 0 { return file }
        for index in 0..<2_600 {
            let candidate = remainder + index * 99_173
            if candidate % divisor == 0 { return candidate / divisor }
        }
        return -1
    }

    private func voiceLineUnlocked(shipID: String, filename: String) -> String? {
        if shipID == "9998" || shipID == "9999" { return filename }
        if let special = Self.specialShipVoices[shipID]?[filename] { return special }
        var shipCache = voiceDiffCache[shipID] ?? [:]
        let difference: Int
        if let cached = shipCache[filename] {
            difference = cached
        } else {
            guard let computed = Self.computeVoiceDiff(shipID: shipID, filename: filename) else {
                return nil
            }
            difference = computed
            shipCache[filename] = computed
            voiceDiffCache[shipID] = shipCache
        }
        let index = Self.specialDiffs[difference]
            ?? Self.voiceDiffs.firstIndex(of: difference)
        return String(index.map { $0 + 1 } ?? difference)
    }

    private func resolveRequest(url: String, path: String) -> (shipID: String, voiceLine: String)? {
        if url.contains("/kcs/sound/kc") {
            let info = path
                .replacingOccurrences(of: "/kcs/sound/kc", with: "")
                .replacingOccurrences(of: ".mp3", with: "")
            let pieces = info.split(separator: "/", omittingEmptySubsequences: true)
            guard pieces.count >= 2 else { return nil }
            let filename = String(pieces[pieces.count - 2])
            let code = String(pieces.last!)
            let shipID = filenameToShipID[filename] ?? filename
            guard Int(shipID) != nil,
                  let line = voiceLineUnlocked(shipID: shipID, filename: code)
            else { return nil }
            return (shipID, line)
        }
        if url.contains("/voice/titlecall_") {
            let info = path
                .replacingOccurrences(of: "/kcs2/resources/voice/", with: "")
                .replacingOccurrences(of: ".mp3", with: "")
            let pieces = info.split(separator: "/", omittingEmptySubsequences: true)
            guard pieces.count >= 2 else { return nil }
            return (String(pieces[pieces.count - 2]), String(pieces.last!))
        }
        return nil
    }

    private func kc3Quote(
        shipID: String,
        voiceLine: String,
        voiceSize: String,
        month: Int,
        remaining: Int
    ) -> (text: String, delay: Int, special: Bool)? {
        var inherited: (text: String, delay: Int, special: Bool)?
        if remaining > 0, let previous = previousShipByID[shipID] {
            inherited = kc3Quote(
                shipID: previous,
                voiceLine: voiceLine,
                voiceSize: voiceSize,
                month: month,
                remaining: remaining - 1
            )
        }

        let catalogShipID: String
        if shipID == "9998" { catalogShipID = "abyssal" }
        else if shipID == "9999" { catalogShipID = "npc" }
        else { catalogShipID = shipID }
        guard let ship = kc3Quotes[catalogShipID] as? [String: Any] else {
            return inherited
        }

        let isSpecialShip = shipID == "9998" || shipID == "9999"
            || shipID.contains("titlecall")
        var key = voiceLine
        var currentIsSpecial = false
        if !isSpecialShip {
            if let sizedKey = sizedQuoteKey(
                shipID: shipID,
                voiceLine: voiceLine,
                voiceSize: voiceSize,
                month: month
            ) {
                key = sizedKey
                currentIsSpecial = sizedKey != voiceLine
            } else if let label = quoteLabels[voiceLine] {
                key = label
            } else {
                return inherited
            }
        }
        if inherited?.special == true && !currentIsSpecial { return inherited }
        guard let raw = ship[key], let quote = Self.quote(from: raw) else {
            return inherited
        }
        return (quote.text, quote.delay, currentIsSpecial)
    }

    private func sizedQuoteKey(
        shipID: String,
        voiceLine: String,
        voiceSize: String,
        month: Int
    ) -> String? {
        var baseID = shipID
        var remaining = 7
        while remaining > 0, let previous = previousShipByID[baseID] {
            baseID = previous
            remaining -= 1
        }
        if let ship = seasonalQuoteSizes[baseID] as? [String: Any],
           let line = ship[voiceLine] as? [String: Any],
           let size = line[voiceSize] as? [String: Any] {
            for suffix in size.keys.sorted() {
                guard let months = size[suffix] as? [Any],
                      months.contains(where: { Self.intValue($0) == month })
                else { continue }
                return "\(voiceLine)@\(suffix)"
            }
        }
        if let ship = quoteSizes[shipID] as? [String: Any],
           let line = ship[voiceLine] as? [String: Any],
           let suffix = Self.stringValue(line[voiceSize]) {
            return suffix.isEmpty ? voiceLine : "\(voiceLine)@\(suffix)"
        }
        return nil
    }

    private func wikiQuote(shipID: String, voiceLine: String, remaining: Int) -> String? {
        if let ship = kcwikiQuotes[shipID] as? [String: Any],
           let value = Self.stringValue(ship[voiceLine]) {
            return value
        }
        guard remaining > 0, let previous = previousShipByID[shipID] else { return nil }
        return wikiQuote(shipID: previous, voiceLine: voiceLine, remaining: remaining - 1)
    }

    private func hourlyDelay(for voiceLine: String) -> Int64 {
        guard let value = Int(voiceLine), (30...53).contains(value) else { return 0 }
        let current = now()
        let currentComponents = calendar.dateComponents([.year, .month, .day], from: current)
        var targetComponents = currentComponents
        targetComponents.hour = value - 30
        targetComponents.minute = 0
        targetComponents.second = 0
        guard var target = calendar.date(from: targetComponents) else { return 0 }
        if value == 30 || target < current {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return Int64(target.timeIntervalSince(current) * 1_000)
    }

    private func updateTiming(from data: [String: Any]) {
        guard let timing = data["timing"] as? [String: Any], timing.count == 2,
              let base = Self.intValue(timing["baseMillisVoiceLine"]),
              let extra = Self.intValue(timing["extraMillisPerChar"])
        else { return }
        baseMillisVoiceLine = base
        extraMillisPerCharacter = extra
    }

    private static func quote(from raw: Any) -> (text: String, delay: Int)? {
        if let text = raw as? String { return (text, 0) }
        guard let timed = raw as? [String: Any] else { return nil }
        return timed.compactMap { key, value -> (String, Int, String)? in
            let start = key.split(separator: ",").first.map(String.init) ?? key
            guard let delay = Int(start), let text = stringValue(value) else { return nil }
            return (key, delay, text)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }
        .first
        .map { ($0.2, $0.1) }
    }

    private static func object(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw CatalogError.invalidJSONObject
        }
        return dictionary
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
