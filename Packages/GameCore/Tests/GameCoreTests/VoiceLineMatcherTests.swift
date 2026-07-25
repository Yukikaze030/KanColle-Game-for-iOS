import Foundation
import XCTest
@testable import GameCore

final class VoiceLineMatcherTests: XCTestCase {
    private let encodedLineOne = "436600" // ship 1, diff 2475 => voice line 1

    func testOrdinaryVoiceFilenameMapsToLabelAndQuote() {
        let matcher = VoiceLineMatcher(
            filenameToShipID: ["001": "1"],
            quoteLabels: ["1": "Intro"],
            kc3Quotes: ["1": ["Intro": "Welcome"]]
        )

        XCTAssertEqual(
            VoiceLineMatcher.computeVoiceDiff(shipID: "1", filename: encodedLineOne),
            2475
        )
        XCTAssertEqual(matcher.voiceLine(shipID: "1", filename: encodedLineOne), "1")
        let match = matcher.matchKC3(
            url: "https://w01y.kancolle-server.com/kcs/sound/kc001/436600.mp3",
            path: "/kcs/sound/kc001/436600.mp3",
            voiceSize: "900"
        )
        XCTAssertEqual(match?.text, "Welcome")
        XCTAssertEqual(match?.shipID, "1")
        XCTAssertEqual(match?.voiceLine, "1")
        XCTAssertEqual(match?.durationMilliseconds, 3_000)
    }

    func testRemodelFallsBackThroughPreviousShipChain() {
        let matcher = VoiceLineMatcher(
            filenameToShipID: ["003": "3"],
            previousShipByID: ["3": "2", "2": "1"],
            quoteLabels: ["1": "Intro"],
            kc3Quotes: ["1": ["Intro": ["250,0": "Original voice"]]]
        )

        let match = matcher.matchKC3(
            url: "https://w01y.kancolle-server.com/kcs/sound/kc003/520750.mp3",
            path: "/kcs/sound/kc003/520750.mp3",
            voiceSize: "700"
        )

        // 520750 encodes ship 3's first voice line by the same KC3 algorithm.
        XCTAssertEqual(matcher.voiceLine(shipID: "3", filename: "520750"), "1")
        XCTAssertEqual(match?.text, "Original voice")
        XCTAssertEqual(match?.delayMilliseconds, 250)
    }

    func testSeasonalFileSizeUsesBaseRemodelShipAndOverridesFallback() {
        let matcher = VoiceLineMatcher(
            filenameToShipID: ["002": "2"],
            previousShipByID: ["2": "1"],
            quoteLabels: ["1": "Intro"],
            seasonalQuoteSizes: [
                "1": [
                    "1": [
                        "12345": ["Summer": [7, 8]]
                    ]
                ]
            ],
            kc3Quotes: [
                "1": ["Intro": "Base ordinary"],
                "2": ["1@Summer": "Kai seasonal"]
            ]
        )

        // ship 2: 17*(2+7)*2475 + 100000 = 478675
        let match = matcher.matchKC3(
            url: "https://w01y.kancolle-server.com/kcs/sound/kc002/478675.mp3",
            path: "/kcs/sound/kc002/478675.mp3",
            voiceSize: "12345",
            month: 7
        )

        XCTAssertEqual(match?.text, "Kai seasonal")
        XCTAssertEqual(match?.voiceLine, "1")
    }

    func testGenericFileSizeSuffixAndKCWikiRemodelFallback() {
        let matcher = VoiceLineMatcher(
            filenameToShipID: ["002": "2"],
            previousShipByID: ["2": "1"],
            quoteLabels: ["1": "Intro"],
            quoteSizes: ["2": ["1": ["321": "Event"]]],
            kc3Quotes: ["2": ["1@Event": "Event quote"]],
            kcwikiQuotes: ["1": ["1": "中文台词"]]
        )
        let url = "https://w01y.kancolle-server.com/kcs/sound/kc002/478675.mp3"
        let path = "/kcs/sound/kc002/478675.mp3"

        XCTAssertEqual(
            matcher.matchKC3(url: url, path: path, voiceSize: "321")?.text,
            "Event quote"
        )
        XCTAssertEqual(matcher.matchKCWiki(url: url, path: path)?.text, "中文台词")
    }

    func testSpecialShipsAndMalformedPathsAreSafe() {
        let matcher = VoiceLineMatcher()
        XCTAssertEqual(matcher.voiceLine(shipID: "9998", filename: "12"), "12")
        XCTAssertEqual(matcher.voiceLine(shipID: "432", filename: "917"), "917")
        XCTAssertNil(matcher.voiceLine(shipID: "abc", filename: "bad"))
        XCTAssertNil(matcher.matchKC3(url: "/kcs/sound/kc", path: "/bad", voiceSize: "1"))
    }

    func testConvenienceInitializerParsesLabelsSizesAndTiming() throws {
        let labels = Data(#"{"1":"Intro","specialQuotesSizes":{}}"#.utf8)
        let quotes = Data(#"{"timing":{"baseMillisVoiceLine":1000,"extraMillisPerChar":10},"1":{"Intro":"abcd"}}"#.utf8)
        let matcher = try VoiceLineMatcher(
            filenameToShipID: ["001": "1"],
            quoteLabelData: labels,
            kc3QuoteData: quotes
        )

        let match = matcher.matchKC3(
            url: "/kcs/sound/kc001/436600.mp3",
            path: "/kcs/sound/kc001/436600.mp3",
            voiceSize: "1"
        )
        XCTAssertEqual(match?.durationMilliseconds, 1_040)
    }
}
