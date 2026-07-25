import Foundation
import XCTest
@testable import GameCore

final class SubtitleStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testKC3LocaleChecksCommitAndAtomicallyCachesQuotes() async throws {
        let recorder = RequestRecorder()
        let store = try SubtitleStore(cacheDirectory: directory) { request, _ in
            await recorder.append(request.url!)
            if request.url!.host == "api.github.com" {
                return .init(statusCode: 200, body: Data(#"[{"sha":"abc123"}]"#.utf8))
            }
            return .init(statusCode: 200, body: Data(#"{"1":{"Intro":"hello"}}"#.utf8))
        }

        let version = try await store.update(locale: .english)
        XCTAssertEqual(version.value, "abc123")
        let cached = try await store.cachedQuotes(for: .english)
        XCTAssertEqual(cached, Data(#"{"1":{"Intro":"hello"}}"#.utf8))
        let cachedVersion = try await store.cachedVersion(for: .english)
        XCTAssertEqual(cachedVersion, "abc123")

        let urls = await recorder.values
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].host, "api.github.com")
        XCTAssertEqual(
            URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value,
            "data/en/quotes.json"
        )
        XCTAssertEqual(
            urls[1].absoluteString,
            "https://raw.githubusercontent.com/KC3Kai/kc3-translations/abc123/data/en/quotes.json"
        )
    }

    func testKCWikiLocaleAndFilenameMapping() async throws {
        let recorder = RequestRecorder()
        let body = Data(#"{"version":"2026.07","1":{"1":"台词"}}"#.utf8)
        let store = try SubtitleStore(cacheDirectory: directory) { request, _ in
            await recorder.append(request.url!)
            return .init(statusCode: 200, body: body)
        }

        let result = try await store.update(locale: .traditionalChinese)
        XCTAssertEqual(result.value, "2026.07")
        let fileURL = await store.quotesFileURL(for: .traditionalChinese)
        XCTAssertEqual(fileURL.lastPathComponent, "quotes_kcwiki_zh-tw.json")
        XCTAssertEqual(try Data(contentsOf: fileURL), body)
        let urls = await recorder.values
        XCTAssertEqual(urls.map(\.path), ["/subtitles/version", "/subtitles/zh-tw"])
    }

    func testInvalidDownloadDoesNotReplaceExistingCache() async throws {
        let old = Data(#"{"old":true}"#.utf8)
        let initial = try SubtitleStore(cacheDirectory: directory) { request, _ in
            if request.url!.host == "api.github.com" {
                return .init(statusCode: 200, body: Data(#"[{"sha":"one"}]"#.utf8))
            }
            return .init(statusCode: 200, body: old)
        }
        _ = try await initial.update(locale: .japanese)

        let failing = try SubtitleStore(cacheDirectory: directory) { request, _ in
            if request.url!.host == "api.github.com" {
                return .init(statusCode: 200, body: Data(#"[{"sha":"two"}]"#.utf8))
            }
            return .init(statusCode: 200, body: Data("not-json".utf8))
        }
        do {
            _ = try await failing.update(locale: .japanese)
            XCTFail("Expected invalid JSON")
        } catch {
            XCTAssertEqual(error as? SubtitleStore.StoreError, .invalidJSON)
        }
        let cached = try await failing.cachedQuotes(for: .japanese)
        XCTAssertEqual(cached, old)
        let version = try await failing.cachedVersion(for: .japanese)
        XCTAssertEqual(version, "one")
    }

    func testResponseLimitAppliesToHeaderBodyAndDisk() async throws {
        let body = Data(repeating: 0x61, count: 33)
        let store = try SubtitleStore(cacheDirectory: directory, maximumResponseBytes: 32) { _, _ in
            .init(statusCode: 200, headers: ["Content-Length": "33"], body: body)
        }
        do {
            _ = try await store.latestVersion(for: .simplifiedChinese)
            XCTFail("Expected response size failure")
        } catch {
            XCTAssertEqual(
                error as? SubtitleStore.StoreError,
                .responseTooLarge(limit: 32)
            )
        }

        let fileURL = await store.quotesFileURL(for: .simplifiedChinese)
        try body.write(to: fileURL)
        do {
            _ = try await store.cachedQuotes(for: .simplifiedChinese)
            XCTFail("Expected disk size failure")
        } catch {
            XCTAssertEqual(
                error as? SubtitleStore.StoreError,
                .responseTooLarge(limit: 32)
            )
        }
    }

    func testKC3QuoteSizeURLAndCache() async throws {
        let recorder = RequestRecorder()
        let sizes = Data(#"{"1":{"1":{"100":"Summer"}}}"#.utf8)
        let store = try SubtitleStore(cacheDirectory: directory) { request, _ in
            await recorder.append(request.url!)
            if request.url!.host == "api.github.com" {
                return .init(statusCode: 200, body: Data(#"[{"sha":"meta456"}]"#.utf8))
            }
            return .init(statusCode: 200, body: sizes)
        }

        let version = try await store.updateKC3QuoteSizes()
        XCTAssertEqual(version.value, "meta456")
        let cached = try await store.cachedQuoteSizes()
        XCTAssertEqual(cached, sizes)
        let cachedVersion = try await store.cachedQuoteSizesVersion()
        XCTAssertEqual(cachedVersion, "meta456")
        let urls = await recorder.values
        XCTAssertEqual(
            urls[1].absoluteString,
            "https://raw.githubusercontent.com/KC3Kai/KC3Kai/meta456/src/data/quotes_size.json"
        )
    }

    func testHTTPFailureAndMissingVersionAreReported() async throws {
        let failed = try SubtitleStore(cacheDirectory: directory) { _, _ in
            .init(statusCode: 503, body: Data())
        }
        do {
            _ = try await failed.latestVersion(for: .english)
            XCTFail("Expected status failure")
        } catch {
            XCTAssertEqual(error as? SubtitleStore.StoreError, .invalidHTTPStatus(503))
        }

        let empty = try SubtitleStore(cacheDirectory: directory) { _, _ in
            .init(statusCode: 200, body: Data("[]".utf8))
        }
        do {
            _ = try await empty.latestVersion(for: .english)
            XCTFail("Expected missing version")
        } catch {
            XCTAssertEqual(error as? SubtitleStore.StoreError, .missingVersion)
        }
    }
}

private actor RequestRecorder {
    private(set) var values: [URL] = []
    func append(_ url: URL) { values.append(url) }
}
