import XCTest
@testable import GameCore

final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        // ensure the suite is removed even if the test fails midway
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testDefaults() {
        let s = SettingsStore(defaults: makeDefaults())
        XCTAssertEqual(s.connector, .dmm)
        XCTAssertTrue(s.cacheEnabled)
        XCTAssertFalse(s.silentStart)
        XCTAssertFalse(s.alterGadget)
        XCTAssertEqual(s.subtitleFontSize, 18)
        XCTAssertEqual(s.cursorMode, .touch)
        XCTAssertTrue(s.legacyRenderer)
        XCTAssertTrue(s.mitmEnabled)
        XCTAssertTrue(s.downloadRetry)
        XCTAssertTrue(s.memoryWarnEnabled)
        XCTAssertEqual(s.alterGadgetEndpoint, BrowserConstants.defaultAlterGadgetURL)
    }
    func testRoundTrip() {
        let d = makeDefaults()
        var s = SettingsStore(defaults: d)
        s.connector = .ooi
        s.silentStart = true
        s.mitmEnabled = false
        let s2 = SettingsStore(defaults: d)
        XCTAssertEqual(s2.connector, .ooi)
        XCTAssertTrue(s2.silentStart)
        XCTAssertFalse(s2.mitmEnabled)
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
    func testJSSnippetRegression() {
        // iOS bridge replacement must be present in CAPTURE_LISTEN
        XCTAssertTrue(BrowserConstants.captureListen.contains("messageHandlers.gotoBrowser"))
        XCTAssertFalse(BrowserConstants.captureListen.contains("GotoBrowser.kcs_process_canvas_dataurl"))
        // MUTE_SEND keeps its %d Int placeholder for String(format:)
        XCTAssertTrue(BrowserConstants.muteSendDMM.contains("%d"))
        XCTAssertTrue(BrowserConstants.muteSendOOI.contains("%d"))
        // autocomplete uses %@ (Swift String safe), not the Android %s
        XCTAssertTrue(BrowserConstants.autocompleteDMM.contains("%@"))
        XCTAssertFalse(BrowserConstants.autocompleteDMM.contains("%s"))
        XCTAssertTrue(BrowserConstants.autocompleteOOI.contains("%@"))
        XCTAssertFalse(BrowserConstants.autocompleteOOI.contains("%s"))
    }
}
