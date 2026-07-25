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
}
