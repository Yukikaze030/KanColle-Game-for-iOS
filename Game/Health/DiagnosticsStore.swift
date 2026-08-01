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
    private(set) var persistenceFailureCount = 0
    private(set) var latestPersistenceFailure: String?

    private(set) var memorySamples: [MemorySample] = []
    private(set) var sessionPeakMemoryMB: Double = 0
    private(set) var systemMemoryWarningCount = 0
    private(set) var recoveryLimitExceededCount: Int
    private(set) var lastRecoveryLimitTerminationCount: Int?
    private(set) var lastRecoveryLimitExceededAt: Date?
    private(set) var canvasToWebGLFallbackCount: Int
    private(set) var lastCanvasToWebGLFallbackAt: Date?

    private let defaults: UserDefaults

    private enum PersistenceKey {
        static let recoveryLimitExceededCount = "diagnostics.recoveryLimitExceededCount"
        static let lastRecoveryLimitTerminationCount = "diagnostics.lastRecoveryLimitTerminationCount"
        static let lastRecoveryLimitExceededAt = "diagnostics.lastRecoveryLimitExceededAt"
        static let canvasToWebGLFallbackCount = "diagnostics.canvasToWebGLFallbackCount"
        static let lastCanvasToWebGLFallbackAt = "diagnostics.lastCanvasToWebGLFallbackAt"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recoveryLimitExceededCount = defaults.integer(
            forKey: PersistenceKey.recoveryLimitExceededCount
        )
        if defaults.object(
            forKey: PersistenceKey.lastRecoveryLimitTerminationCount
        ) != nil {
            lastRecoveryLimitTerminationCount = defaults.integer(
                forKey: PersistenceKey.lastRecoveryLimitTerminationCount
            )
        }
        lastRecoveryLimitExceededAt = defaults.object(
            forKey: PersistenceKey.lastRecoveryLimitExceededAt
        ) as? Date
        canvasToWebGLFallbackCount = defaults.integer(
            forKey: PersistenceKey.canvasToWebGLFallbackCount
        )
        lastCanvasToWebGLFallbackAt = defaults.object(
            forKey: PersistenceKey.lastCanvasToWebGLFallbackAt
        ) as? Date
    }

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

    /// Keeps persistence faults distinct from API parsing/network faults.
    /// Error text is bounded because it is shown in the diagnostic UI.
    func recordPersistenceFailure(store: String, error: Error) {
        persistenceFailureCount += 1
        latestPersistenceFailure = "\(Self.sanitize(store, limit: 16)): \(Self.sanitize(error.localizedDescription, limit: 192))"
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
            "database_bytes=\(p3DatabaseSizeBytes)",
            "persistence_failures=\(persistenceFailureCount)",
            "latest_persistence_failure=\(latestPersistenceFailure ?? "—")"
        ].joined(separator: "\n")
    }

    func recordMemorySample(residentMB: Double, at date: Date = Date()) {
        memorySamples.append(.init(date: date, residentMB: residentMB))
        sessionPeakMemoryMB = max(sessionPeakMemoryMB, residentMB)
        if memorySamples.count > 60 {
            memorySamples.removeFirst(memorySamples.count - 60)
        }
    }

    var currentMemorySample: MemorySample? {
        memorySamples.last
    }

    func recordSystemMemoryWarning() {
        systemMemoryWarningCount += 1
    }

    /// Records that automatic WebContent recovery stopped after reaching its
    /// retry limit. Persisted values remain available after relaunch.
    func recordRecoveryLimitExceeded(
        terminationCount: Int,
        at date: Date = Date()
    ) {
        let safeTerminationCount = max(0, terminationCount)
        recoveryLimitExceededCount += 1
        lastRecoveryLimitTerminationCount = safeTerminationCount
        lastRecoveryLimitExceededAt = date
        defaults.set(
            recoveryLimitExceededCount,
            forKey: PersistenceKey.recoveryLimitExceededCount
        )
        defaults.set(
            safeTerminationCount,
            forKey: PersistenceKey.lastRecoveryLimitTerminationCount
        )
        defaults.set(date, forKey: PersistenceKey.lastRecoveryLimitExceededAt)
    }

    /// Records a Canvas to WebGL safety fallback. The aggregate count and
    /// latest occurrence are persisted for diagnostics.
    func recordCanvasToWebGLFallback(at date: Date = Date()) {
        canvasToWebGLFallbackCount += 1
        lastCanvasToWebGLFallbackAt = date
        defaults.set(
            canvasToWebGLFallbackCount,
            forKey: PersistenceKey.canvasToWebGLFallbackCount
        )
        defaults.set(date, forKey: PersistenceKey.lastCanvasToWebGLFallbackAt)
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
