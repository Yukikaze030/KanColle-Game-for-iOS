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
        XCTAssertFalse(s.heavyDamageLockedOnly)
        XCTAssertEqual(s.heavyDamageMinimumLevel, 0)
        XCTAssertEqual(s.notificationLeadTimeSeconds, 61)
        XCTAssertEqual(s.alterGadgetEndpoint, BrowserConstants.defaultAlterGadgetURL)
    }
    func testP2SafetySettingsClampUnsafeValues() {
        var s = SettingsStore(defaults: makeDefaults())
        s.heavyDamageLockedOnly = true
        s.heavyDamageMinimumLevel = -1
        s.notificationLeadTimeSeconds = 999
        XCTAssertTrue(s.heavyDamageLockedOnly)
        XCTAssertEqual(s.heavyDamageMinimumLevel, 0)
        XCTAssertEqual(s.notificationLeadTimeSeconds, 600)

        s.notificationLeadTimeSeconds = -5
        XCTAssertEqual(s.notificationLeadTimeSeconds, 0)
    }
    func testRoundTrip() {
        let d = makeDefaults()
        var s = SettingsStore(defaults: d)
        s.connector = .ooi
        s.silentStart = true
        s.cacheEnabled = false
        s.legacyRenderer = false
        s.cursorMode = .mouse
        s.keepScreenOn = true
        s.subtitleEnabled = true
        s.subtitleLocale = "tcn"
        s.subtitleFontSize = 24
        s.alterGadget = true
        s.alterGadgetEndpoint = "https://cache.example.test/"
        s.downloadRetry = false
        s.mitmEnabled = false
        s.memoryWarnEnabled = false
        s.memoryWarnThresholdMB = 768
        let s2 = SettingsStore(defaults: d)
        XCTAssertEqual(s2.connector, .ooi)
        XCTAssertTrue(s2.silentStart)
        XCTAssertFalse(s2.cacheEnabled)
        XCTAssertFalse(s2.legacyRenderer)
        XCTAssertEqual(s2.cursorMode, .mouse)
        XCTAssertTrue(s2.keepScreenOn)
        XCTAssertTrue(s2.subtitleEnabled)
        XCTAssertEqual(s2.subtitleLocale, "tcn")
        XCTAssertEqual(s2.subtitleFontSize, 24)
        XCTAssertTrue(s2.alterGadget)
        XCTAssertEqual(s2.alterGadgetEndpoint, "https://cache.example.test/")
        XCTAssertFalse(s2.downloadRetry)
        XCTAssertFalse(s2.mitmEnabled)
        XCTAssertFalse(s2.memoryWarnEnabled)
        XCTAssertEqual(s2.memoryWarnThresholdMB, 768)
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
