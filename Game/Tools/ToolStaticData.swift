import Foundation
import Combine

/// User-initiated, cached downloads of the public data files used by the native tools.
/// Nothing is fetched during game play; a failed update keeps the last verified local copy.
@MainActor
final class ToolStaticData: ObservableObject {
    struct Expedition: Identifiable, Decodable {
        struct Name: Decodable { let jp: String?; let en: String?; let scn: String?; let tcn: String? }
        let no: String
        let area: Int?
        let name: Name
        let time: Int?
        let resource: [Int]?
        let reward: [[Int]]?
        let exp: [Int]?
        let totalNum: Int?
        let flagLevel: Int?

        enum CodingKeys: String, CodingKey { case no, area, name, time, resource, reward, exp; case totalNum = "total-num"; case flagLevel = "flag-lv" }
        var id: String { no }
        var displayName: String { name.scn ?? name.tcn ?? name.en ?? name.jp ?? "远征 #\(no)" }
    }

    struct AkashiEntry: Identifiable {
        struct Improvement {
            let upgradeItemID: Int?
            let upgradeLevel: Int?
            let days: Set<Int>
            let secretaryShipIDs: [Int]
            let resources: [Int]
        }
        let id: Int
        let improvements: [Improvement]
        let defaultEquippedOn: [Int]
    }

    @Published private(set) var levelTable: [Int: (next: Int, total: Int)] = [:]
    @Published private(set) var expeditions: [Expedition] = []
    /// Requirement summaries derived from poi-plugin-ezexped's public checker rules.
    @Published private(set) var expeditionRequirements: [Int: [String]] = [:]
    @Published private(set) var akashi: [Int: AkashiEntry] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUpdating = false

    private let session: URLSession
    private let directory: URL
    private let sourceBase = URL(string: "https://raw.githubusercontent.com/antest1/kcanotify/master/app/src/main/assets/")!
    private let ezExpedBase = URL(string: "https://raw.githubusercontent.com/poooi/poi-plugin-ezexped/refs/heads/master/exped-reqs/")!

    init(session: URLSession = .shared, directory: URL? = nil) {
        self.session = session
        self.directory = directory ?? Self.defaultDirectory()
        loadCached()
    }

    func update() async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["exp_ship.json", "expedition.json", "akashi_data.json"] {
                let (data, response) = try await session.data(from: sourceBase.appendingPathComponent(name))
                guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                    throw URLError(.badServerResponse)
                }
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
            // The poi source is JavaScript, not executable content: it is treated strictly
            // as text and reduced to display-only requirement summaries below.
            for name in ["world-1.es", "world-2.es", "world-3.es", "world-4.es", "world-5.es", "world-7.es"] {
                let (data, response) = try await session.data(from: ezExpedBase.appendingPathComponent(name))
                guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                    throw URLError(.badServerResponse)
                }
                try data.write(to: directory.appendingPathComponent("ezexped-\(name)"), options: .atomic)
            }
            loadCached()
            lastUpdated = Date()
        } catch {
            errorMessage = "工具数据更新失败：\(error.localizedDescription)"
        }
    }

    func dismissError() { errorMessage = nil }

    private func loadCached() {
        levelTable = Self.decodeLevelTable(data(named: "exp_ship.json"))
        expeditions = Self.decodeExpeditions(data(named: "expedition.json"))
        akashi = Self.decodeAkashi(data(named: "akashi_data.json"))
        expeditionRequirements = Self.decodeExpeditionRequirements(directory: directory)
        if lastUpdated == nil {
            lastUpdated = try? directory.appendingPathComponent("akashi_data.json")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    private func data(named name: String) -> Data? { try? Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe) }
    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ToolStaticData", isDirectory: true)
    }

    private static func decodeLevelTable(_ data: Data?) -> [Int: (next: Int, total: Int)] {
        guard let data, let raw = try? JSONDecoder().decode([String: [Int]].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let level = Int(key), value.count >= 2 else { return nil }
            return (level, (next: value[0], total: value[1]))
        })
    }

    private static func decodeExpeditions(_ data: Data?) -> [Expedition] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Expedition].self, from: data)) ?? []
    }

    private static func decodeAkashi(_ data: Data?) -> [Int: AkashiEntry] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: root.compactMap { key, raw in
            guard let id = Int(key), let object = raw as? [String: Any] else { return nil }
            let equipped = object["default_equipped_on"] as? [Int] ?? []
            let improvements = (object["improvement"] as? [[String: Any]] ?? []).map { item in
                let upgrade = item["upgrade"] as? [Int]
                let request = (item["req"] as? [[[Any]]] ?? []).first
                let days = Set(((request?.first as? [Bool]) ?? []).enumerated().compactMap { $0.element ? $0.offset : nil })
                let secretaries = (request?.dropFirst().first as? [Int]) ?? []
                let resources = ((item["resource"] as? [[Int]])?.first) ?? []
                return AkashiEntry.Improvement(upgradeItemID: upgrade?.first, upgradeLevel: upgrade?.dropFirst().first, days: days, secretaryShipIDs: secretaries, resources: resources)
            }
            return (id, AkashiEntry(id: id, improvements: improvements, defaultEquippedOn: equipped))
        })
    }

    private static func decodeExpeditionRequirements(directory: URL) -> [Int: [String]] {
        let names = ["world-1.es", "world-2.es", "world-3.es", "world-4.es", "world-5.es", "world-7.es"]
        return names.reduce(into: [:]) { result, name in
            guard let text = try? String(contentsOf: directory.appendingPathComponent("ezexped-\(name)"), encoding: .utf8) else { return }
            for (id, block) in expeditionBlocks(in: text) { result[id] = requirementLabels(in: block) }
        }
    }

    private static func expeditionBlocks(in text: String) -> [(Int, String)] {
        let pattern = #"defineExped\s*(?:/\*[^*]*\*/\s*)?\(\s*(\d+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: full)
        return matches.enumerated().compactMap { index, match in
            guard let range = Range(match.range(at: 1), in: text), let id = Int(text[range]) else { return nil }
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (text as NSString).length
            let block = (text as NSString).substring(with: NSRange(location: start, length: end - start))
            return (id, block)
        }
    }

    private static func requirementLabels(in block: String) -> [String] {
        var values: [String] = []
        func captures(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: block, range: NSRange(block.startIndex..., in: block)).map { match in
                (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: block).map { String(block[$0]) } }
            }
        }
        for item in captures(#"fslSc\(\s*(\d+)\s*,\s*(\d+)\s*\)"#) { values += ["旗舰等级 ≥ \(item[0])", "舰船数 ≥ \(item[1])"] }
        let numeric = [("LevelSum", "舰队总等级"), ("TotalFirepower", "总火力"), ("TotalAntiAir", "总对空"), ("TotalAsw", "总对潜"), ("TotalLos", "总索敌"), ("Morale", "士气")]
        for (key, label) in numeric {
            for item in captures("mk\\.\(key)\\(\\s*(\\d+)\\s*\\)") { values.append("\(label) ≥ \(item[0])") }
        }
        for item in captures(#"\{\s*([^{}]+)\s*\}"#) where item[0].contains(":") {
            let ships = item[0].split(separator: ",").map { component -> String in
                let pair = component.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return pair.count == 2 ? "\(shipTypeName(pair[0])) × \(pair[1])" : String(component)
            }.joined(separator: "，")
            values.append("编成：\(ships)")
        }
        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private static func shipTypeName(_ value: String) -> String {
        ["CL": "轻巡", "DD": "驱逐", "DE": "海防", "DDorDE": "驱逐或海防", "CT": "练巡", "CVE": "护卫空母", "CA": "重巡", "CAV": "航巡", "CV": "正规空母", "CVL": "轻空母", "BB": "战舰", "BBV": "航战", "SS": "潜艇", "SSV": "潜母", "AV": "水母", "AO": "补给舰", "AS": "潜母", "LHA": "两栖攻击舰"][value] ?? value
    }
}
