import Foundation
import GameCore

/// Measures only the app-managed game cache cleared by `SettingsView`.
///
/// The scope intentionally excludes the rest of the app sandbox and WebKit's
/// private storage. It includes `browser_cache/resources`, the VersionStore
/// SQLite file and any SQLite sidecar files under the same cache root.
enum CacheUsageMonitor {
    nonisolated static func cacheRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                BrowserConstants.cacheDirName,
                isDirectory: true
            )
    }

    /// Recursively scans the cache root on a detached task so directory
    /// enumeration and resource-value reads never block the main thread.
    nonisolated static func usageBytes() async throws -> Int64 {
        let root = cacheRootURL()
        return try await Task.detached(priority: .utility) {
            try calculateUsageBytes(at: root)
        }.value
    }

    nonisolated private static func calculateUsageBytes(
        at root: URL
    ) throws -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return 0 }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // Cache files may be replaced while scanning. Skip an entry that
            // disappears instead of failing the whole user-facing refresh.
            guard let values = try? fileURL.resourceValues(forKeys: keys) else {
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(max(0, size))
        }
        return total
    }
}
