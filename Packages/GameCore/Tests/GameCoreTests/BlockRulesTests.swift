import XCTest
@testable import GameCore

final class BlockRulesTests: XCTestCase {
    func testBlocked() {
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://ad.doubleclick.net/x"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://www.dmm.com/latest/js/dmm.tracking.js"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://osapi.dmm.com/uikit/js/x.js"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://www.googletagmanager.com/gtm.js"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://www.facebook.com/tr"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://twitter.com/i/jot"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://pics.dmm.com/ad/banner.png"))
    }

    func testAllowed() {
        XCTAssertFalse(BlockRules.isBlocked(urlString: "http://w01g.kancolle-server.com/kcs2/js/main.js"))
        XCTAssertFalse(BlockRules.isBlocked(urlString: "https://play.games.dmm.com/game/kancolle"))
    }

    func testBlockedHost() {
        XCTAssertTrue(BlockRules.isBlocked(host: "ad.doubleclick.net"))
        XCTAssertTrue(BlockRules.isBlocked(host: "www.googletagmanager.com"))
        XCTAssertTrue(BlockRules.isBlocked(host: "www.facebook.com"))
        XCTAssertTrue(BlockRules.isBlocked(host: "pics.dmm.com"))
        // 含路径的规则不参与 host 阻断：
        XCTAssertFalse(BlockRules.isBlocked(host: "play.games.dmm.com"))
        XCTAssertFalse(BlockRules.isBlocked(host: "www.dmm.com"))
        XCTAssertFalse(BlockRules.isBlocked(host: "twitter.com"))
        XCTAssertFalse(BlockRules.isBlocked(host: "w01g.kancolle-server.com"))
    }

    func testPathScopedRulesStillBlockFullURL() {
        // host 阻断放行的路径级规则，在完整 URL 层面仍然生效
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://www.dmm.com/latest/js/dmm.tracking.js"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://twitter.com/i/jot"))
        XCTAssertTrue(BlockRules.isBlocked(urlString: "https://osapi.dmm.com/uikit/js/x.js"))
    }
}
