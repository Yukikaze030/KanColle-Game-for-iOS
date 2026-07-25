import XCTest
@testable import GameCore

final class SettingsStoreTests: XCTestCase {
    func testDefaults() {
        let s = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        XCTAssertEqual(s.connector, .dmm)
        XCTAssertTrue(s.cacheEnabled)
        XCTAssertFalse(s.silentStart)
        XCTAssertFalse(s.alterGadget)
        XCTAssertEqual(s.subtitleFontSize, 18)
        XCTAssertEqual(s.cursorMode, .touch)
    }
    func testRoundTrip() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        var s = SettingsStore(defaults: d)
        s.connector = .ooi
        s.silentStart = true
        let s2 = SettingsStore(defaults: d)
        XCTAssertEqual(s2.connector, .ooi)
        XCTAssertTrue(s2.silentStart)
    }
    func testBlockRulesPorted() {
        XCTAssertTrue(BrowserConstants.blockRules.contains("doubleclick.net"))
        XCTAssertEqual(BrowserConstants.blockRules.count, 7)
    }
    func testUAStrings() {
        XCTAssertTrue(BrowserConstants.userAgentDesktop.contains("Chrome/142.0.0.0"))
        XCTAssertTrue(BrowserConstants.userAgentIOSCanvas.contains("Safari/605.1.15"))
        XCTAssertTrue(BrowserConstants.userAgentMobile.contains("Mobile Safari/537.36"))
    }
}
