import XCTest
import Network
@testable import GameCore

final class LocalProxyIntegrationTests: XCTestCase {
    private var proxy: LocalProxyServer?

    override func tearDown() {
        proxy?.stop()
        proxy = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func inc() { lock.lock(); _value += 1; lock.unlock() }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
    }

    /// 起假上游：收到任意数据后回固定响应并关闭。返回 (listener, counter)。
    private func startUpstream(response: String, counter: Counter) throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            counter.inc()
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                guard data != nil else { conn.cancel(); return }
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        listener.start(queue: .global())
        return listener
    }

    /// 轮询等待端口就绪（listener ready 前 port 为 0）。
    private func waitPort(_ get: @escaping () -> UInt16, timeout: TimeInterval = 5) -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let p = get()
            if p != 0 { return p }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return 0
    }

    /// 连接 127.0.0.1:port，依次发送 chunks（可模拟分包到达），
    /// 累积接收直到 isComplete 或收到 marker。
    private func roundTrip(port: UInt16, chunks: [String], marker: String,
                           timeout: TimeInterval = 5) -> String? {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "client ready")
        conn.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        conn.start(queue: .global())
        wait(for: [ready], timeout: timeout)

        // 串行发送，保证分包边界
        func sendChunks(_ rest: ArraySlice<String>) {
            guard let first = rest.first else { return }
            conn.send(content: Data(first.utf8), completion: .contentProcessed { _ in
                sendChunks(rest.dropFirst())
            })
        }
        sendChunks(chunks[...])
        let received = Box(Data())
        let got = expectation(description: "got \(marker)")
        got.assertForOverFulfill = false
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                var acc = received.value
                if let data { acc.append(data) }
                received.set(acc)
                if String(data: acc, encoding: .utf8)?.contains(marker) == true || isComplete {
                    got.fulfill()
                } else {
                    receive()
                }
            }
        }
        receive()
        wait(for: [got], timeout: timeout)
        conn.cancel()
        return String(data: received.value, encoding: .utf8)
    }

    private func roundTrip(port: UInt16, request: String, marker: String,
                           timeout: TimeInterval = 5) -> String? {
        roundTrip(port: port, chunks: [request], marker: marker, timeout: timeout)
    }

    // MARK: - Tests

    func testPlainHTTPForwarding() throws {
        let upstreamCounter = Counter()
        let upstream = try startUpstream(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            counter: upstreamCounter)
        defer { upstream.cancel() }
        let upstreamPort = waitPort { upstream.port?.rawValue ?? 0 }
        XCTAssertNotEqual(upstreamPort, 0)

        let proxy = LocalProxyServer()
        self.proxy = proxy
        let logs = Box<[ProxyRequestLog]>([])
        proxy.onRequest = { logs.set(logs.value + [$0]) }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let response = roundTrip(
            port: proxyPort,
            request: "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\n\r\n",
            marker: "hello")
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("hello"))
        XCTAssertEqual(upstreamCounter.value, 1)

        let log = logs.value.first { $0.path == "/" }
        XCTAssertNotNil(log)
        XCTAssertEqual(log?.blocked, false)
        XCTAssertEqual(log?.statusCode, 200)
    }

    func testBlockedConnectHost() throws {
        let proxy = LocalProxyServer()
        self.proxy = proxy
        proxy.onGameResourceRequest = nil
        let logs = Box<[ProxyRequestLog]>([])
        proxy.onRequest = { logs.set(logs.value + [$0]) }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let response = roundTrip(
            port: proxyPort,
            request: "CONNECT ad.doubleclick.net:443 HTTP/1.1\r\n\r\n",
            marker: "403")
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("403"))

        let log = logs.value.first { $0.host == "ad.doubleclick.net" }
        XCTAssertNotNil(log)
        XCTAssertEqual(log?.blocked, true)
    }

    func testLocalResponseShortCircuit() throws {
        let upstreamCounter = Counter()
        let upstream = try startUpstream(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            counter: upstreamCounter)
        defer { upstream.cancel() }
        let upstreamPort = waitPort { upstream.port?.rawValue ?? 0 }
        XCTAssertNotEqual(upstreamPort, 0)

        let proxy = LocalProxyServer()
        self.proxy = proxy
        proxy.isInspectableHost = { _, _ in true }
        proxy.onGameResourceRequest = { _ in
            ResourceResponse(statusCode: 200,
                             headers: [("Content-Type", "text/plain")],
                             body: Data("cached".utf8))
        }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let response = roundTrip(
            port: proxyPort,
            request: "GET /kcs2/x.js HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\n\r\n",
            marker: "cached")
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("cached"))
        XCTAssertEqual(upstreamCounter.value, 0, "短路响应不应触达上游")
    }

    func testNonInspectableHostBypassesCallback() throws {
        // 非检查 host（默认 isInspectableHost 只认 kancolle-server.com:80）不应询问短路回调
        let upstreamCounter = Counter()
        let upstream = try startUpstream(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            counter: upstreamCounter)
        defer { upstream.cancel() }
        let upstreamPort = waitPort { upstream.port?.rawValue ?? 0 }
        XCTAssertNotEqual(upstreamPort, 0)

        let proxy = LocalProxyServer()
        self.proxy = proxy
        let callbackCalled = Box(false)
        proxy.onGameResourceRequest = { _ in
            callbackCalled.set(true)
            return ResourceResponse(statusCode: 200, headers: [], body: Data("cached".utf8))
        }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let response = roundTrip(
            port: proxyPort,
            request: "GET /x.js HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\n\r\n",
            marker: "hello")
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("hello"), "非检查 host 应回源转发")
        XCTAssertFalse(callbackCalled.value, "非检查 host 不应询问 onGameResourceRequest")
        XCTAssertEqual(upstreamCounter.value, 1)
    }

    func testNegativeContentLengthDoesNotCrash() throws {
        let upstreamCounter = Counter()
        let upstreamReceived = Box(Data())
        let upstream = try NWListener(using: .tcp, on: .any)
        upstream.newConnectionHandler = { conn in
            upstreamCounter.inc()
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if let data { upstreamReceived.set(upstreamReceived.value + data) }
                conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        upstream.start(queue: .global())
        defer { upstream.cancel() }
        let upstreamPort = waitPort { upstream.port?.rawValue ?? 0 }
        XCTAssertNotEqual(upstreamPort, 0)

        let proxy = LocalProxyServer()
        self.proxy = proxy
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let response = roundTrip(
            port: proxyPort,
            request: "POST /x HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\nContent-Length: -5\r\n\r\n",
            marker: "ok")
        XCTAssertNotNil(response, "非法 Content-Length 不应导致崩溃/无响应")
        XCTAssertTrue(response!.contains("ok"))
        XCTAssertEqual(upstreamCounter.value, 1, "非法 Content-Length 按 0 body 转发")
    }

    func testResourceResponseReasonPhrases() {
        func firstLine(_ code: Int) -> String {
            let data = ResourceResponse(statusCode: code, headers: [], body: Data()).serialized()
            return String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        }
        XCTAssertEqual(firstLine(200), "HTTP/1.1 200 OK")
        XCTAssertEqual(firstLine(302), "HTTP/1.1 302 Found")
        XCTAssertEqual(firstLine(304), "HTTP/1.1 304 Not Modified")
        XCTAssertEqual(firstLine(403), "HTTP/1.1 403 Forbidden")
        XCTAssertEqual(firstLine(404), "HTTP/1.1 404 Not Found")
        XCTAssertEqual(firstLine(502), "HTTP/1.1 502 Bad Gateway")
        XCTAssertEqual(firstLine(418), "HTTP/1.1 418 Response")
    }

    func testPostBodyForwarding() throws {
        // 上游：累积接收直到收满 body "hello=world"，记录完整请求后回 200
        let upstreamCounter = Counter()
        let upstreamReceived = Box(Data())
        let upstream = try NWListener(using: .tcp, on: .any)
        upstream.newConnectionHandler = { conn in
            upstreamCounter.inc()
            conn.start(queue: .global())
            func recv() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                    var acc = upstreamReceived.value
                    if let data { acc.append(data) }
                    upstreamReceived.set(acc)
                    if String(data: acc, encoding: .utf8)?.contains("hello=world") == true {
                        conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8),
                                  completion: .contentProcessed { _ in conn.cancel() })
                    } else if isComplete {
                        conn.cancel()
                    } else {
                        recv()
                    }
                }
            }
            recv()
        }
        upstream.start(queue: .global())
        defer { upstream.cancel() }
        let upstreamPort = waitPort { upstream.port?.rawValue ?? 0 }
        XCTAssertNotEqual(upstreamPort, 0)

        let proxy = LocalProxyServer()
        self.proxy = proxy
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        // body 分两个包发送，验证代理按 Content-Length 收满后再转发
        let head = "POST /kcsapi/api_start2/getData HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\n"
        let response = roundTrip(
            port: proxyPort,
            chunks: [head + "hello=", "world"],
            marker: "ok")
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains("ok"))
        XCTAssertEqual(upstreamCounter.value, 1)

        let got = String(data: upstreamReceived.value, encoding: .utf8)
        XCTAssertNotNil(got)
        XCTAssertTrue(got!.contains("Content-Length: 11"), "转发应保留原始 Content-Length")
        XCTAssertTrue(got!.hasSuffix("hello=world"), "上游收到的 body 必须完整，实际收到：\(got!)")
    }
}
