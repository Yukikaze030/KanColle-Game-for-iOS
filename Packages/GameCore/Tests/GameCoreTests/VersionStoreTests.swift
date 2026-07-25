import Foundation
import XCTest
@testable import GameCore

final class VersionStoreTests: XCTestCase {
    private func makePath() -> String {
        NSTemporaryDirectory() + "vstore-\(UUID().uuidString).db"
    }

    func testSetGet() throws {
        let store = try VersionStore(path: makePath())
        try store.put(
            key: "/kcs2/js/main.js",
            version: "12345",
            lastModified: "Wed, 01 Jan 2025 00:00:00 GMT",
            maxAgeSeconds: 3_600
        )

        let row = try store.get(key: "/kcs2/js/main.js")
        XCTAssertEqual(row?.key, "/kcs2/js/main.js")
        XCTAssertEqual(row?.version, "12345")
        XCTAssertEqual(row?.lastModified, "Wed, 01 Jan 2025 00:00:00 GMT")
        XCTAssertEqual(row?.maxAgeSeconds, 3_600)
        XCTAssertEqual(row?.fetchedAt.timeIntervalSinceNow ?? .infinity, 0, accuracy: 2)
    }

    func testOverwrite() throws {
        let store = try VersionStore(path: makePath())
        try store.put(key: "a", version: "1", lastModified: nil, maxAgeSeconds: nil)
        try store.put(key: "a", version: "2", lastModified: nil, maxAgeSeconds: nil)

        XCTAssertEqual(try store.get(key: "a")?.version, "2")
    }

    func testNilColumnsAndMissingKey() throws {
        let store = try VersionStore(path: makePath())
        try store.put(key: "nil-fields", version: nil, lastModified: nil, maxAgeSeconds: nil)

        let row = try XCTUnwrap(store.get(key: "nil-fields"))
        XCTAssertNil(row.version)
        XCTAssertNil(row.lastModified)
        XCTAssertNil(row.maxAgeSeconds)
        XCTAssertNil(try store.get(key: "missing"))
    }

    func testBoundParametersPreserveQuotes() throws {
        let store = try VersionStore(path: makePath())
        let key = "a' OR 1=1 --"
        try store.put(key: key, version: "\"quoted\"", lastModified: "it's valid", maxAgeSeconds: 1)

        let row = try XCTUnwrap(store.get(key: key))
        XCTAssertEqual(row.version, "\"quoted\"")
        XCTAssertEqual(row.lastModified, "it's valid")
        XCTAssertNil(try store.get(key: "a"))
    }

    func testRemoveAll() throws {
        let store = try VersionStore(path: makePath())
        try store.put(key: "a", version: "1", lastModified: nil, maxAgeSeconds: nil)
        try store.put(key: "b", version: "2", lastModified: nil, maxAgeSeconds: nil)

        try store.removeAll()

        XCTAssertNil(try store.get(key: "a"))
        XCTAssertNil(try store.get(key: "b"))
    }

    func testPersistsAcrossInstances() throws {
        let path = makePath()
        do {
            let store = try VersionStore(path: path)
            try store.put(key: "persisted", version: "v1", lastModified: nil, maxAgeSeconds: 10)
        }

        let reopened = try VersionStore(path: path)
        XCTAssertEqual(try reopened.get(key: "persisted")?.version, "v1")
    }

    func testSQLiteOpenOrSchemaErrorIsThrown() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vstore-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        XCTAssertThrowsError(try VersionStore(path: directory.path))
    }

    func testCorruptSQLiteFileThrowsSchemaError() throws {
        let path = makePath()
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try VersionStore(path: path))
    }

    func testConcurrentAccessIsSerializedSafely() throws {
        let store = try VersionStore(path: makePath())
        let queue = DispatchQueue(label: "VersionStoreTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var errors: [Error] = []
        var mismatches: [String] = []

        for index in 0..<100 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let key = "key-\(index)"
                    try store.put(key: key, version: "\(index)", lastModified: nil, maxAgeSeconds: index)
                    let actual = try store.get(key: key)?.version
                    if actual != "\(index)" {
                        lock.lock()
                        mismatches.append("\(key): \(actual ?? "nil")")
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.isEmpty, "Unexpected SQLite errors: \(errors)")
        XCTAssertTrue(mismatches.isEmpty, "Unexpected rows: \(mismatches)")
    }
}
