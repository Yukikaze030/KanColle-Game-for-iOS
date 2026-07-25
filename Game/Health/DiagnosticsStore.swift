import Foundation
import Observation

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

    private(set) var memorySamples: [MemorySample] = []

    func recordProcessTermination(at date: Date = Date()) {
        processTerminationCount += 1
        lastProcessTermination = date
    }

    func recordNavigationError(_ description: String) {
        navigationErrors.append("\(ISO8601DateFormatter().string(from: Date())) \(description)")
        if navigationErrors.count > 50 { navigationErrors.removeFirst() }
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
        proxyLogs.append(line)
        if proxyLogs.count > 100 { proxyLogs.removeFirst(proxyLogs.count - 100) }
    }
}
