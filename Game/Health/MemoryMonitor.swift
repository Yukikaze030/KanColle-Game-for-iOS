import Foundation
import Observation
import UIKit
import MachO

/// Monitors the host app process's physical footprint. Public iOS APIs cannot
/// read the separate WKWebContent process footprint, so system memory warnings
/// and `webViewWebContentProcessDidTerminate` remain the primary WebView OOM
/// signals.
@MainActor
@Observable final class MemoryMonitor {
    enum Level: Sendable {
        case normal
        case warning
    }

    private(set) var residentMB: Double = 0
    private(set) var level: Level = .normal
    private(set) var thresholdMB: Double

    var onThresholdExceeded: (() -> Void)?
    var onSystemMemoryWarning: (() -> Void)?

    private var timer: Timer?
    private var warningObserver: NSObjectProtocol?
    private var warnedForCurrentPeak = false
    private let diagnostics: DiagnosticsStore
    private let sampleInterval: TimeInterval

    init(
        thresholdMB: Double? = nil,
        sampleInterval: TimeInterval = 5,
        diagnostics: DiagnosticsStore? = nil
    ) {
        self.thresholdMB = max(
            128,
            thresholdMB ?? Self.recommendedThresholdMB()
        )
        self.sampleInterval = max(1, sampleInterval)
        self.diagnostics = diagnostics ?? .shared
    }

    func updateThresholdMB(_ value: Double?) {
        thresholdMB = max(128, value ?? Self.recommendedThresholdMB())
        evaluateLevel()
    }

    func start() {
        guard timer == nil else { return }
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
                self?.diagnostics.recordSystemMemoryWarning()
                self?.onSystemMemoryWarning?()
            }
        }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        timer?.tolerance = min(1, sampleInterval * 0.2)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let warningObserver {
            NotificationCenter.default.removeObserver(warningObserver)
            self.warningObserver = nil
        }
    }

    func sample() {
        guard let megabytes = Self.currentPhysicalFootprintMB() else { return }
        residentMB = megabytes
        diagnostics.recordMemorySample(residentMB: megabytes)
        evaluateLevel()
    }

    private func evaluateLevel() {
        let overThreshold = residentMB >= thresholdMB
        level = overThreshold ? .warning : .normal
        if overThreshold, !warnedForCurrentPeak {
            warnedForCurrentPeak = true
            onThresholdExceeded?()
        } else if residentMB < thresholdMB * 0.85 {
            // Hysteresis prevents an alert loop while usage oscillates near the
            // configured threshold.
            warnedForCurrentPeak = false
        }
    }

    private static func currentPhysicalFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    private static func recommendedThresholdMB() -> Double {
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory)
            / 1_073_741_824
        switch physicalGB {
        case ..<3.5: return 180
        case ..<5: return 260
        case ..<7: return 380
        default: return 512
        }
    }
}
