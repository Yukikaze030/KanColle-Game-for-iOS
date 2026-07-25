import XCTest
@testable import GameCore

final class ProxyHTTPParserTests: XCTestCase {
    func testParseGetRequest() {
        var p = ProxyHTTPParser()
        let raw = "GET /kcs2/resources/ship/full/0001.png?ver=3 HTTP/1.1\r\nHost: w01g.kancolle-server.com\r\nAccept: */*\r\n\r\n"
        let result = p.feed(Data(raw.utf8))
        guard case .request(let req) = result else { return XCTFail() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/kcs2/resources/ship/full/0001.png?ver=3")
        XCTAssertEqual(req.host, "w01g.kancolle-server.com")
        XCTAssertEqual(req.header("accept"), "*/*")
    }

    func testParseConnect() {
        var p = ProxyHTTPParser()
        let raw = "CONNECT play.games.dmm.com:443 HTTP/1.1\r\nHost: play.games.dmm.com:443\r\n\r\n"
        guard case .connect(let host, let port) = p.feed(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(host, "play.games.dmm.com")
        XCTAssertEqual(port, 443)
    }

    func testIncrementalFeed() {
        var p = ProxyHTTPParser()
        XCTAssertEqual(p.feed(Data("GET /a".utf8)), .needMore)
        let rest = " HTTP/1.1\r\nHost: x.com\r\n\r\n"
        guard case .request = p.feed(Data(rest.utf8)) else { return XCTFail() }
    }
}
