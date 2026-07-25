import Foundation

enum SharedContainer {
    static let appGroupIdentifier = "group.KanColle.Game.shared"

    nonisolated static func snapshotDatabaseURL() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("P2", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("game-state.sqlite")
    }
}
