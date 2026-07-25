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
}
