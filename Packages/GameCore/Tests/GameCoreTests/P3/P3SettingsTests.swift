import XCTest
@testable import GameCore

final class P3SettingsTests: XCTestCase {
    func testDefaultsFavorFunctionalityWithoutEnemyDetailMemoryCost() {
        let name = "p3.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)

        XCTAssertTrue(settings.battleOverlayAutoRefresh)
        XCTAssertFalse(settings.showEnemyEquipmentDetails)
        XCTAssertEqual(settings.battleLogRetentionCount, 50)
        XCTAssertTrue(settings.exactQuestTrackingEnabled)
        XCTAssertTrue(settings.questCompletionBannerEnabled)
        XCTAssertTrue(settings.parsedDataHUDEnabled)
    }

    func testOnlyDocumentedRetentionCapacitiesAreAccepted() {
        let name = "p3.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = SettingsStore(defaults: defaults)

        for value in [20, 50, 100] {
            settings.battleLogRetentionCount = value
            XCTAssertEqual(settings.battleLogRetentionCount, value)
        }
        settings.battleLogRetentionCount = Int.max
        XCTAssertEqual(settings.battleLogRetentionCount, 50)

        settings.parsedDataHUDEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).parsedDataHUDEnabled)
    }
}
