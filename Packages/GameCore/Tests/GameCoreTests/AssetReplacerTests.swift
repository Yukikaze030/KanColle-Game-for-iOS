import Foundation
import XCTest
@testable import GameCore

final class AssetReplacerTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var replacer: AssetReplacer!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetReplacerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )

        let fixtures: [String: Data] = [
            "A-OTF-UDShinGoPro-Light.woff2": Data("wOF2-light".utf8),
            "A-OTF-UDShinGoPro-Regular.woff2": Data("wOF2-regular".utf8),
            "maintenance.html": Data("<html>maintenance</html>".utf8),
            "maintenance.png": Data([0x89, 0x50, 0x4e, 0x47]),
            "tweenjs-0.6.2.min.js": Data("window.createjs={};".utf8),
            "rollover.js": Data("window.rollover=true;".utf8),
            "kcs_cda.js": Data("window.kcsCda=true;".utf8),
            "ooi.css": Data("body{margin:0}".utf8)
        ]
        for (name, data) in fixtures {
            try data.write(to: fixtureDirectory.appendingPathComponent(name))
        }
        replacer = AssetReplacer(resourceDirectory: fixtureDirectory)
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        fixtureDirectory = nil
        replacer = nil
    }

    func testReplacesOnlyBundledFontNamesWithWoff2MIME() {
        let light = replacer.replacement(
            forPath: "/kcs2/resources/font/A-OTF-UDShinGoPro-Light.woff2?version=1"
        )
        let regular = replacer.replacement(
            forPath: "https://w00g.kancolle-server.com/kcs2/font/A-OTF-UDShinGoPro-Regular.woff2"
        )

        XCTAssertEqual(light?.0.prefix(4), Data("wOF2".utf8))
        XCTAssertEqual(light?.1, "font/woff2")
        XCTAssertEqual(regular?.0, Data("wOF2-regular".utf8))
        XCTAssertEqual(regular?.1, "font/woff2")
        XCTAssertNil(replacer.replacement(forPath: "/font/A-OTF-UDShinGoPro-Bold.woff2"))
        XCTAssertNil(replacer.replacement(forPath: "/font/not-bundled.woff2"))
    }

    func testReplacesKnownScriptsAndStylesWithCorrectMIME() {
        assertReplacement(
            path: "/gadget_html5/script/rollover.js",
            contains: "rollover",
            mimeType: "application/javascript"
        )
        assertReplacement(
            path: "/gadget_html5/js/kcs_cda.js",
            contains: "kcsCda",
            mimeType: "application/javascript"
        )
        assertReplacement(
            path: "/lib/tweenjs.min.js",
            contains: "createjs",
            mimeType: "application/javascript"
        )
        assertReplacement(path: "/styles/ooi.css", contains: "margin", mimeType: "text/css")
    }

    func testReplacesMaintenanceFilesByExactPathSuffix() {
        let html = replacer.replacement(forPath: "/kcs2/resources/html/maintenance.html")
        let image = replacer.replacement(forPath: "/kcs2/resources/html/maintenance.png#ignored")

        XCTAssertEqual(html?.0, Data("<html>maintenance</html>".utf8))
        XCTAssertEqual(html?.1, "text/html")
        XCTAssertEqual(image?.0, Data([0x89, 0x50, 0x4e, 0x47]))
        XCTAssertEqual(image?.1, "image/png")
    }

    func testRejectsLookalikeAndUnsafePaths() {
        XCTAssertNil(replacer.replacement(forPath: "/evil/rollover.js"))
        XCTAssertNil(replacer.replacement(forPath: "/gadget_html5/script/rollover.js.backup"))
        XCTAssertNil(replacer.replacement(forPath: "/gadget_html5/script/../script/rollover.js"))
        XCTAssertNil(replacer.replacement(forPath: "/font/%2e%2e/A-OTF-UDShinGoPro-Light.woff2"))
        XCTAssertNil(replacer.replacement(forPath: "/gadget_html5%2Fscript%2Frollover.js"))
        XCTAssertNil(replacer.replacement(forPath: "rollover.js"))
        XCTAssertNil(replacer.replacement(forPath: "/gadget_html5\\script\\rollover.js"))
        XCTAssertNil(replacer.replacement(forPath: "/unknown/game_custom.css"))
    }

    func testMissingFixtureReturnsNilInsteadOfFallingBackToAnotherBundle() throws {
        try FileManager.default.removeItem(
            at: fixtureDirectory.appendingPathComponent("maintenance.html")
        )

        XCTAssertNil(replacer.replacement(forPath: "/html/maintenance.html"))
    }

    private func assertReplacement(path: String, contains text: String, mimeType: String) {
        let result = replacer.replacement(forPath: path)
        XCTAssertEqual(result?.1, mimeType)
        XCTAssertTrue(
            result.flatMap { String(data: $0.0, encoding: .utf8) }?.contains(text) == true
        )
    }
}
