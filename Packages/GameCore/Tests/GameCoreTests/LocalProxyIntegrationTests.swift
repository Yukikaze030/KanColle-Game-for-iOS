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

    /// 连接 127.0.0.1:port，发送 request，累积接收直到 isComplete 或收到 marker。
    private func roundTrip(port: UInt16, request: String, marker: String,
                           timeout: TimeInterval = 5) -> String? {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "client ready")
        conn.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        conn.start(queue: .global())
        wait(for: [ready], timeout: timeout)

        conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
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
}
