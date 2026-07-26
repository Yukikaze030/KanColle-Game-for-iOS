import Foundation
import Observation
import GameCore

@MainActor
@Observable final class DiagnosticsStore {
    struct MemorySample: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let residentMB: Double
    }

    static let shared = DiagnosticsStore()
    private(set) var processTerminationCount = 0
    private(set) var lastProcessTermination: Date?
    private(set) var navigationErrors: [String] = []
    private(set) var latestGameEndpoint: String?
    private(set) var battleRevision: Int64 = 0
    private(set) var questRevision: Int64 = 0
    private(set) var p3WarningCount = 0
    private(set) var rankMismatchCount = 0
    private(set) var p3DatabaseSizeBytes: Int64 = 0

    private(set) var memorySamples: [MemorySample] = []

    func recordProcessTermination(at date: Date = Date()) {
        processTerminationCount += 1
        lastProcessTermination = date
    }

    func recordNavigationError(_ description: String) {
        navigationErrors.append(
            "\(ISO8601DateFormatter().string(from: Date())) \(Self.sanitize(description, limit: 256))"
        )
        if navigationErrors.count > 50 { navigationErrors.removeFirst() }
    }

    func recordP3Endpoint(_ rawEndpoint: String, battleRevision: Int64, questRevision: Int64) {
        latestGameEndpoint = Self.endpointPath(rawEndpoint)
        self.battleRevision = max(self.battleRevision, battleRevision)
        self.questRevision = max(self.questRevision, questRevision)
    }

    func recordP3Warnings(_ count: Int) {
        p3WarningCount += max(0, count)
    }

    func recordRankMismatch() {
        rankMismatchCount += 1
    }

    func updateP3DatabaseSize(at url: URL?) {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            p3DatabaseSizeBytes = 0
            return
        }
        p3DatabaseSizeBytes = max(0, size.int64Value)
    }

    /// Deliberately excludes raw response/request data, account identity and
    /// browser URLs. This value is safe to copy from the settings screen.
    var sanitizedP3Summary: String {
        [
            "endpoint=\(latestGameEndpoint ?? "—")",
            "battle_revision=\(battleRevision)",
            "quest_revision=\(questRevision)",
            "warnings=\(p3WarningCount)",
            "rank_mismatches=\(rankMismatchCount)",
            "database_bytes=\(p3DatabaseSizeBytes)"
        ].joined(separator: "\n")
    }

    func recordMemorySample(residentMB: Double, at date: Date = Date()) {
        memorySamples.append(.init(date: date, residentMB: residentMB))
        if memorySamples.count > 60 {
            memorySamples.removeFirst(memorySamples.count - 60)
        }
    }

    // 代理日志保留为诊断信息，设置页只展示最近记录。
    private(set) var proxyLogs: [String] = []
    func recordProxyLog(_ line: String) {
        proxyLogs.append(Self.sanitize(line, limit: 256))
        if proxyLogs.count > 100 { proxyLogs.removeFirst(proxyLogs.count - 100) }
    }

    private static func endpointPath(_ rawValue: String) -> String {
        let normalized = APIEnvelopeParser.normalizeEndpoint(rawValue)
        return sanitize(normalized, limit: 128)
    }

    private static func sanitize(_ value: String, limit: Int) -> String {
        var sanitized = value
        for key in ["api_token", "token", "member_id", "nickname", "login_id", "password"] {
            let pattern = "(?i)(\(NSRegularExpression.escapedPattern(for: key)))(=|:)[^&\\s]+"
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "$1$2<redacted>",
                options: .regularExpression
            )
        }
        return String(sanitized.prefix(limit))
    }
}
