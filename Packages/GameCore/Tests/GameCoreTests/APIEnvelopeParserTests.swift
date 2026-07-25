import XCTest
@testable import GameCore

final class APIEnvelopeParserTests: XCTestCase {
    private let parser = APIEnvelopeParser()

    func testStripsSVDataNormalizesEndpointAndFiltersToken() throws {
        let response = Data("  svdata={\"api_result\":1,\"api_data\":{\"value\":7}}\n".utf8)
        let request = Data("api_token=secret-token&api_deck_id=2&name=hello+world".utf8)
        let envelope = try parser.parse(
            endpoint: "https://w00g.kancolle-server.com/kcsapi//api_get_member/deck?api_token=leak",
            response: response,
            requestBody: request
        )

        XCTAssertEqual(envelope.endpoint, "/api_get_member/deck")
        XCTAssertEqual(envelope.apiResult, 1)
        XCTAssertEqual(envelope.data?.objectValue?["value"]?.intValue, 7)
        XCTAssertNil(envelope.requestParameters["api_token"])
        XCTAssertFalse(String(describing: envelope).contains("secret-token"))
        XCTAssertEqual(envelope.requestParameters["api_deck_id"], "2")
        XCTAssertEqual(envelope.requestParameters["name"], "hello world")
    }

    func testAcceptsPlainJSONAndEndpointVariants() throws {
        let data = Data("{\"api_result\":1,\"api_data\":[]}".utf8)
        XCTAssertEqual(try parser.parse(endpoint: "/kcsapi/api_port/port/", response: data).endpoint, "/api_port/port")
        XCTAssertEqual(try parser.parse(endpoint: "api_start2", response: data).endpoint, "/api_start2")
    }

    func testRejectsBadJSONAndNonObjectRoot() {
        XCTAssertThrowsError(try parser.parse(endpoint: "/api_port/port", response: Data("svdata={bad".utf8))) {
            XCTAssertEqual($0 as? APIEnvelopeParser.ParseError, .invalidJSON)
        }
        XCTAssertThrowsError(try parser.parse(endpoint: "/api_port/port", response: Data("[]".utf8))) {
            XCTAssertEqual($0 as? APIEnvelopeParser.ParseError, .rootIsNotObject)
        }
        XCTAssertThrowsError(try parser.parse(endpoint: "/api_port/port", response: Data(" svdata= ".utf8))) {
            XCTAssertEqual($0 as? APIEnvelopeParser.ParseError, .emptyResponse)
        }
    }
}
