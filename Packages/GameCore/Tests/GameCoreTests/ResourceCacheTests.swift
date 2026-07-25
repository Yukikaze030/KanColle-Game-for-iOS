import Foundation
import XCTest
@testable import GameCore

final class ResourceCacheTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: VersionStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        suiteName = "ResourceCacheTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = try VersionStore(
            path: temporaryDirectory.appendingPathComponent("versions.sqlite")
                .path
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        store = nil
        defaults = nil
        suiteName = nil
        temporaryDirectory = nil
    }

    private func head(
        method: String = "GET",
        path: String = "/kcs2/img/ship.png?ver=1",
        host: String = "w01y.kancolle-server.com",
        port: Int = 443
    ) -> ProxyHTTPParser.HTTPRequestHead {
        .init(
            method: method,
            path: path,
            host: host,
            port: port,
            headers: [
                ("Host", host),
                ("User-Agent", "ResourceCacheTests")
            ]
        )
    }

    private func makeCache(
        assets: URL? = nil,
        maxBytes: Int = 1_024,
        now: @escaping () -> Date = Date.init,
        fetcher: @escaping ResourceFetcher
    ) -> ResourceCache {
        ResourceCache(
            cacheDir: temporaryDirectory.appendingPathComponent("cache"),
            versionStore: store,
            settings: SettingsStore(defaults: defaults),
            assetReplacer: assets.map(AssetReplacer.init(resourceDirectory:))
                ?? AssetReplacer(resourceDirectory: temporaryDirectory),
            scriptPatcher: nil,
            maximumResponseBytes: maxBytes,
            now: now,
            fetcher: fetcher
        )
    }

    func testAssetReplacementHasPriorityOverHostAndNetwork() throws {
        let assets = temporaryDirectory.appendingPathComponent("assets")
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        let font = Data("wOF2fixture".utf8)
        try font.write(
            to: assets.appendingPathComponent(
                "A-OTF-UDShinGoPro-Regular.woff2"
            )
        )
        var fetchCount = 0
        let cache = makeCache(assets: assets) { _, _ in
            fetchCount += 1
            return .init(statusCode: 500, headers: [], body: Data())
        }

        let response = cache.response(for: head(
            path: "/font/A-OTF-UDShinGoPro-Regular.woff2",
            host: "example.com"
        ))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.body, font)
        XCTAssertEqual(
            response?.headers.first?.1,
            "font/woff2"
        )
        XCTAssertEqual(fetchCount, 0)
    }

    func testNonGameHostPassesThrough() {
        var fetchCount = 0
        let cache = makeCache { _, _ in
            fetchCount += 1
            return .init(statusCode: 200, headers: [], body: Data())
        }

        XCTAssertNil(cache.response(for: head(host: "example.com")))
        XCTAssertNil(cache.response(for: head(host: "evil-kancolle-server.com")))
        XCTAssertEqual(fetchCount, 0)
    }

    func testGadgetEndpointMappingPreservesPathAndQuery() {
        defaults.set(true, forKey: "pref_alter_gadget")
        defaults.set(
            "https://cache.example.test/root/",
            forKey: "pref_alter_endpoint"
        )
        var fetchedURL: URL?
        let cache = makeCache { request, _ in
            fetchedURL = request.url
            return .init(
                statusCode: 200,
                headers: [("Cache-Control", "max-age=60")],
                body: Data("gadget".utf8)
            )
        }

        let response = cache.response(for: head(
            path: "/gadget_html5/script/app.js?ver=42"
        ))

        XCTAssertEqual(response?.body, Data("gadget".utf8))
        XCTAssertEqual(
            fetchedURL?.absoluteString,
            "https://cache.example.test/root/gadget_html5/script/app.js?ver=42"
        )
    }

    func testFreshCacheHitDoesNotFetchNetwork() throws {
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        var fetchCount = 0
        let cache = makeCache(now: { fixedNow }) { _, _ in
            fetchCount += 1
            return .init(statusCode: 500, headers: [], body: Data())
        }
        let requestHead = head()
        let url = try XCTUnwrap(URL(
            string: "https://w01y.kancolle-server.com\(requestHead.path)"
        ))
        let key = "https://w01y.kancolle-server.com/kcs2/img/ship.png"
        let fileURL = cache.cacheFileURL(forKey: key, originalURL: url)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: fileURL)
        try store.put(
            key: key,
            version: "1",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            maxAgeSeconds: Int.max
        )

        let response = cache.response(for: requestHead)

        XCTAssertEqual(response?.body, Data("old".utf8))
        XCTAssertEqual(fetchCount, 0)
    }

    func testRevalidate304TouchesRowAndReturnsOldBody() throws {
        let requestHead = head()
        let url = try XCTUnwrap(URL(
            string: "https://w01y.kancolle-server.com\(requestHead.path)"
        ))
        let key = "https://w01y.kancolle-server.com/kcs2/img/ship.png"
        var ifModifiedSince: String?
        let cache = makeCache { request, _ in
            ifModifiedSince = request.value(
                forHTTPHeaderField: "If-Modified-Since"
            )
            return .init(
                statusCode: 304,
                headers: [("Cache-Control", "max-age=600")],
                body: Data()
            )
        }
        let fileURL = cache.cacheFileURL(forKey: key, originalURL: url)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: fileURL)
        try store.put(
            key: key,
            version: "1",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT",
            maxAgeSeconds: 0
        )
        let before = try XCTUnwrap(store.get(key: key)?.fetchedAt)

        usleep(20_000)
        let response = cache.response(for: requestHead)

        XCTAssertEqual(
            ifModifiedSince,
            "Mon, 01 Jan 2024 00:00:00 GMT"
        )
        XCTAssertEqual(response?.body, Data("old".utf8))
        let after = try XCTUnwrap(store.get(key: key))
        XCTAssertGreaterThan(after.fetchedAt, before)
        XCTAssertEqual(after.maxAgeSeconds, 600)
    }

    func testRevalidate200AtomicallyReplacesFileAndMetadata() throws {
        let requestHead = head()
        let url = try XCTUnwrap(URL(
            string: "https://w01y.kancolle-server.com\(requestHead.path)"
        ))
        let key = "https://w01y.kancolle-server.com/kcs2/img/ship.png"
        let cache = makeCache { _, _ in
            .init(
                statusCode: 200,
                headers: [
                    ("Last-Modified", "Tue, 02 Jan 2024 00:00:00 GMT"),
                    ("Cache-Control", "public, max-age=120"),
                    ("Content-Type", "image/png")
                ],
                body: Data("new".utf8)
            )
        }
        let fileURL = cache.cacheFileURL(forKey: key, originalURL: url)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: fileURL)
        try store.put(
            key: key,
            version: "1",
            lastModified: "old-date",
            maxAgeSeconds: 0
        )

        let response = cache.response(for: requestHead)

        XCTAssertEqual(response?.body, Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("new".utf8))
        let row = try XCTUnwrap(store.get(key: key))
        XCTAssertEqual(row.version, "1")
        XCTAssertEqual(
            row.lastModified,
            "Tue, 02 Jan 2024 00:00:00 GMT"
        )
        XCTAssertEqual(row.maxAgeSeconds, 120)
    }

    func testNoCacheDownloadsAndPersistsURLVersion() throws {
        var fetchCount = 0
        let cache = makeCache { _, _ in
            fetchCount += 1
            return .init(
                statusCode: 200,
                headers: [
                    ("Last-Modified", "date"),
                    ("Cache-Control", "max-age=30")
                ],
                body: Data("download".utf8)
            )
        }

        XCTAssertEqual(
            cache.response(for: head(path: "/kcs2/js/main.js?ver=v99"))?.body,
            Data("download".utf8)
        )
        XCTAssertEqual(fetchCount, 1)
        let row = try XCTUnwrap(store.get(
            key: "https://w01y.kancolle-server.com/kcs2/js/main.js"
        ))
        XCTAssertEqual(row.version, "v99")
    }

    func testMainScriptIsPatchedWhenServedButOriginalIsCached() throws {
        let cache = ResourceCache(
            cacheDir: temporaryDirectory.appendingPathComponent("cache"),
            versionStore: store,
            settings: SettingsStore(defaults: defaults),
            assetReplacer: AssetReplacer(resourceDirectory: temporaryDirectory),
            fetcher: { _, _ in
                .init(
                    statusCode: 200,
                    headers: [("Cache-Control", "max-age=600")],
                    body: Data("var original=1;".utf8)
                )
            }
        )

        let requestHead = head(path: "/kcs2/js/main.js?ver=patch-test")
        let response = try XCTUnwrap(cache.response(for: requestHead))
        XCTAssertTrue(
            String(decoding: response.body, as: UTF8.self)
                .contains("__GOTO_IOS_BRIDGE_PATCH_V1__")
        )

        let originalURL = try XCTUnwrap(
            URL(string: "https://w01y.kancolle-server.com\(requestHead.path)")
        )
        let fileURL = cache.cacheFileURL(
            forKey: "https://w01y.kancolle-server.com/kcs2/js/main.js",
            originalURL: originalURL
        )
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            Data("var original=1;".utf8)
        )
    }

    func testDisabledCacheAlwaysDownloadsWithoutWriting() throws {
        defaults.set(false, forKey: "pref_cache")
        var fetchCount = 0
        let cache = makeCache { _, _ in
            fetchCount += 1
            return .init(
                statusCode: 200,
                headers: [("Cache-Control", "max-age=600")],
                body: Data("uncached".utf8)
            )
        }

        XCTAssertNotNil(cache.response(for: head()))
        XCTAssertNotNil(cache.response(for: head()))

        XCTAssertEqual(fetchCount, 2)
        XCTAssertNil(try store.get(
            key: "https://w01y.kancolle-server.com/kcs2/img/ship.png"
        ))
    }

    func testVersionChangeDoesNotServeFreshOldFile() throws {
        var fetchCount = 0
        let cache = makeCache { _, _ in
            fetchCount += 1
            return .init(
                statusCode: 200,
                headers: [("Cache-Control", "max-age=600")],
                body: Data("v2".utf8)
            )
        }
        _ = cache.response(for: head(path: "/kcs2/js/main.js?ver=1"))

        let response = cache.response(
            for: head(path: "/kcs2/js/main.js?ver=2")
        )

        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(response?.body, Data("v2".utf8))
        XCTAssertEqual(
            try store.get(
                key: "https://w01y.kancolle-server.com/kcs2/js/main.js"
            )?.version,
            "2"
        )
    }

    func testCacheFilenameIsContainedAndTraversalPathIsRejected() {
        var fetchCount = 0
        let cache = makeCache { _, _ in
            fetchCount += 1
            return .init(statusCode: 200, headers: [], body: Data())
        }
        let malicious = head(path: "/kcs2/%2e%2e/private/secret?ver=1")

        XCTAssertNil(cache.response(for: malicious))
        XCTAssertEqual(fetchCount, 0)

        let original = URL(
            string: "https://w01y.kancolle-server.com/kcs2/a.js"
        )!
        let file = cache.cacheFileURL(
            forKey: "../../outside",
            originalURL: original
        )
        XCTAssertEqual(
            file.deletingLastPathComponent().standardizedFileURL,
            temporaryDirectory.appendingPathComponent("cache")
                .standardizedFileURL
        )
        XCTAssertFalse(file.lastPathComponent.contains(".."))
        XCTAssertTrue(file.lastPathComponent.hasSuffix(".js"))
    }

    func testOnlyGetAndHeadAreHandled() {
        var fetchCount = 0
        let cache = makeCache { _, _ in
            fetchCount += 1
            return .init(
                statusCode: 200,
                headers: [],
                body: Data("body".utf8)
            )
        }

        XCTAssertNil(cache.response(for: head(method: "POST")))
        let headResponse = cache.response(for: head(method: "HEAD"))

        XCTAssertEqual(headResponse?.statusCode, 200)
        XCTAssertEqual(headResponse?.body, Data())
        XCTAssertEqual(fetchCount, 1)
    }

    func testOversizedResponseIsRejectedAndNotPersisted() throws {
        var observedLimit = 0
        let cache = makeCache(maxBytes: 4) { _, limit in
            observedLimit = limit
            return .init(
                statusCode: 200,
                headers: [],
                body: Data(repeating: 1, count: 5)
            )
        }

        XCTAssertNil(cache.response(for: head()))
        XCTAssertEqual(observedLimit, 4)
        XCTAssertNil(try store.get(
            key: "https://w01y.kancolle-server.com/kcs2/img/ship.png"
        ))
    }

    func testResponseHeadersThatConflictWithDecodedBodyAreRemoved() {
        let cache = makeCache { _, _ in
            .init(
                statusCode: 200,
                headers: [
                    ("Content-Type", "application/javascript"),
                    ("Content-Encoding", "gzip"),
                    ("Content-Length", "999"),
                    ("Connection", "keep-alive")
                ],
                body: Data("ok".utf8)
            )
        }

        let response = cache.response(
            for: head(path: "/kcs2/js/main.js")
        )

        XCTAssertEqual(response?.headers.count, 1)
        XCTAssertEqual(response?.headers.first?.0, "Content-Type")
        XCTAssertEqual(
            response?.headers.first?.1,
            "application/javascript"
        )
    }
}
