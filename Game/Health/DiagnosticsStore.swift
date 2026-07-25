import Foundation
import Observation

/// 最小版诊断存储（任务 14 扩展）。
@Observable final class DiagnosticsStore {
    static let shared = DiagnosticsStore()
    private(set) var processTerminationCount = 0
    private(set) var navigationErrors: [String] = []
    func recordProcessTermination() { processTerminationCount += 1 }
    func recordNavigationError(_ description: String) {
        navigationErrors.append(description)
        if navigationErrors.count > 50 { navigationErrors.removeFirst() }
    }

    // TODO(任务6后清理)：Spike 代理/探针日志环形缓冲（任务 14 并入正式诊断）。
    // 仅供主线程写入（调用方负责跳回主线程），UI 直接读取。
    private(set) var proxyLogs: [String] = []
    func recordProxyLog(_ line: String) {
        proxyLogs.append(line)
        if proxyLogs.count > 100 { proxyLogs.removeFirst(proxyLogs.count - 100) }
    }

    // TODO(任务6后清理)：Spike 内存探针日志节流（每 60 秒最多一条）。
    private var lastMemoryLogTime: Date = .distantPast
    func recordMemoryProbeLog(jsHeapMB: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastMemoryLogTime) >= 60 else { return }
        lastMemoryLogTime = now
        recordProxyLog(String(format: "[MEM] %.1fMB", jsHeapMB))
    }
}
