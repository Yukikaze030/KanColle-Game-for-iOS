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
    @Published private(set) var akashi: [Int: AkashiEntry] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUpdating = false

    private let session: URLSession
    private let directory: URL
    private let sourceBase = URL(string: "https://raw.githubusercontent.com/antest1/kcanotify/master/app/src/main/assets/")!

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
}
