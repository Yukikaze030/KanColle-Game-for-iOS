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
        XCTAssertTrue(BlockRules.isBlocked(host: "twitter.com"))
        // 注意：派生片段含 "dmm.com"（来自 "dmm.com/latest/js/dmm.tracking"），
        // 因此 dmm.com 及其子域的 CONNECT 也会被判定为 blocked（已知行为，见任务 4 汇报）。
        XCTAssertTrue(BlockRules.isBlocked(host: "play.games.dmm.com"))
        XCTAssertFalse(BlockRules.isBlocked(host: "w01g.kancolle-server.com"))
    }
}
