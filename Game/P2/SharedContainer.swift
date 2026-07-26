import Foundation

enum SharedContainer {
    static let appGroupIdentifier = "group.KanColle.Game.shared"

    nonisolated static func snapshotDatabaseURL() throws -> URL {
        try databaseURL(directory: "P2", filename: "game-state.sqlite")
    }

    nonisolated static func p3DatabaseURL() throws -> URL {
        try databaseURL(directory: "P3", filename: "battle-quest.sqlite")
    }

    private nonisolated static func databaseURL(
        directory directoryName: String,
        filename: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }
}
