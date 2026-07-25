import Foundation
import XCTest
@testable import GameCore

final class CachePolicyTests: XCTestCase {
    func testFreshByMaxAge() {
        let now = Date()
        let entry = CachePolicy.Entry(
            fetchedAt: now.addingTimeInterval(-100),
            lastModified: nil,
            maxAgeSeconds: 3_600
        )

        XCTAssertTrue(CachePolicy.isFresh(entry, at: now))
    }

    func testExpiredNeedsRevalidate() {
        let now = Date()
        let entry = CachePolicy.Entry(
            fetchedAt: now.addingTimeInterval(-7_200),
            lastModified: "x",
            maxAgeSeconds: 3_600
        )

        XCTAssertFalse(CachePolicy.isFresh(entry, at: now))
    }

    func testMissingZeroAndNegativeMaxAgeAreNotFresh() {
        let now = Date()

        XCTAssertFalse(CachePolicy.isFresh(.init(fetchedAt: now, lastModified: nil, maxAgeSeconds: nil), at: now))
        XCTAssertFalse(CachePolicy.isFresh(.init(fetchedAt: now, lastModified: nil, maxAgeSeconds: 0), at: now))
        XCTAssertFalse(CachePolicy.isFresh(.init(fetchedAt: now, lastModified: nil, maxAgeSeconds: -1), at: now))
    }

    func testExactExpiryBoundaryIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_000)
        let entry = CachePolicy.Entry(
            fetchedAt: now.addingTimeInterval(-60),
            lastModified: nil,
            maxAgeSeconds: 60
        )

        XCTAssertFalse(CachePolicy.isFresh(entry, at: now))
    }

    func testParseCacheControlMaxAge() {
        XCTAssertEqual(CachePolicy.parseMaxAge("public, max-age=86400"), 86_400)
        XCTAssertEqual(CachePolicy.parseMaxAge("MAX-AGE = 120, immutable"), 120)
        XCTAssertNil(CachePolicy.parseMaxAge("no-cache"))
        XCTAssertNil(CachePolicy.parseMaxAge(nil))
    }

    func testParseQuotedMaxAge() {
        XCTAssertEqual(CachePolicy.parseMaxAge("private, max-age=\"3600\""), 3_600)
        XCTAssertEqual(CachePolicy.parseMaxAge("max-age='42'"), 42)
    }

    func testNegativeMalformedAndOverflowMaxAgeAreIgnored() {
        XCTAssertNil(CachePolicy.parseMaxAge("max-age=-1"))
        XCTAssertNil(CachePolicy.parseMaxAge("max-age=not-a-number"))
        XCTAssertNil(CachePolicy.parseMaxAge("max-age=999999999999999999999999999999"))
        XCTAssertNil(CachePolicy.parseMaxAge("max-age"))
        XCTAssertNil(CachePolicy.parseMaxAge("s-maxage=60"))
    }

    func testEmptyDirectiveDoesNotHideLaterValidMaxAge() {
        XCTAssertEqual(CachePolicy.parseMaxAge("max-age=, public, max-age=15"), 15)
    }
}
