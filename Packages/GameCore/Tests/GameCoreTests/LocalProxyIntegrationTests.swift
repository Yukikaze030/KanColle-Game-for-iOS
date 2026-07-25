import XCTest
import Network
import Security
import Security.SecureTransport
@testable import GameCore

private final class ProxyTLSClientBIO {
    var input = Data()
    var output = Data()
    var inputEOF = false
}

private let proxyTLSClientRead: SSLReadFunc = {
    connection,
    destination,
    requestedLength in

    let bio = Unmanaged<ProxyTLSClientBIO>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    let requested = requestedLength.pointee
    let copied = min(requested, bio.input.count)
    if copied > 0 {
        bio.input.copyBytes(
            to: destination.assumingMemoryBound(to: UInt8.self),
            count: copied
        )
        bio.input.removeFirst(copied)
    }
    requestedLength.pointee = copied
    if copied == requested { return errSecSuccess }
    if copied > 0 { return errSSLWouldBlock }
    return bio.inputEOF ? errSSLClosedGraceful : errSSLWouldBlock
}

private let proxyTLSClientWrite: SSLWriteFunc = {
    connection,
    source,
    requestedLength in

    let bio = Unmanaged<ProxyTLSClientBIO>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    let count = requestedLength.pointee
    if count > 0 {
        bio.output.append(
            source.assumingMemoryBound(to: UInt8.self),
            count: count
        )
    }
    return errSecSuccess
}

private final class ProxyTLSClient {
    enum ClientError: Error {
        case setup(OSStatus)
        case invalidConnectResponse
        case trust
        case tls(OSStatus)
    }

    private enum Phase {
        case connecting
        case waitingForConnectResponse
        case tls
        case finished
    }

    private let connection: NWConnection
    private let context: SSLContext
    private let rootCertificate: SecCertificate
    private let host: String
    private let request: Data
    private let coalesceClientHelloWithConnect: Bool
    private let completion: (Result<Data, Error>) -> Void
    private let onTLSOpen: (() -> Void)?
    private let stateQueue = DispatchQueue(
        label: "GameCoreTests.LocalProxyTLSClient"
    )
    private let networkQueue = DispatchQueue(
        label: "GameCoreTests.LocalProxyTLSClient.Network"
    )
    private let bio = ProxyTLSClientBIO()

    private var phase: Phase = .connecting
    private var connectInput = Data()
    private var response = Data()
    private var requestOffset = 0
    private var sendInFlight = false
    private var receiveInFlight = false
    private var tlsOpen = false
    private var didNotifyTLSOpen = false
    private var completed = false

    init(
        proxyPort: UInt16,
        host: String,
        rootCertificate: SecCertificate,
        request: Data,
        coalesceClientHelloWithConnect: Bool = false,
        onTLSOpen: (() -> Void)? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) throws {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw ClientError.setup(errSecAllocate)
        }
        self.context = context
        self.rootCertificate = rootCertificate
        self.host = host
        self.request = request
        self.coalesceClientHelloWithConnect = coalesceClientHelloWithConnect
        self.onTLSOpen = onTLSOpen
        self.completion = completion
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: proxyPort)!,
            using: .tcp
        )

        try Self.check(
            SSLSetIOFuncs(context, proxyTLSClientRead, proxyTLSClientWrite)
        )
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(bio).toOpaque())
        try Self.check(SSLSetConnection(context, pointer))
        try Self.check(SSLSetProtocolVersionMin(context, .tlsProtocol12))
        try Self.check(SSLSetProtocolVersionMax(context, .tlsProtocol12))
        try Self.check(
            SSLSetSessionOption(context, .breakOnServerAuth, true)
        )
        try host.utf8CString.withUnsafeBytes { bytes in
            try Self.check(
                SSLSetPeerDomainName(
                    context,
                    bytes.baseAddress,
                    host.utf8.count
                )
            )
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.stateQueue.async {
                switch state {
                case .ready:
                    self.sendConnect()
                    self.scheduleReceive()
                case .failed(let error):
                    self.finish(.failure(error))
                case .cancelled:
                    if !self.completed {
                        self.finish(.success(self.response))
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: networkQueue)
    }

    private func sendConnect() {
        guard phase == .connecting else { return }
        phase = .waitingForConnectResponse
        var payload = Data(
            "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n".utf8
        )
        if coalesceClientHelloWithConnect {
            let status = SSLHandshake(context)
            guard status == errSSLWouldBlock else {
                finish(.failure(ClientError.tls(status)))
                return
            }
            payload.append(bio.output)
            bio.output.removeAll(keepingCapacity: true)
        }
        sendInFlight = true
        connection.send(
            content: payload,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.stateQueue.async {
                    self.sendInFlight = false
                    if let error {
                        self.finish(.failure(error))
                    } else if self.phase == .tls {
                        self.driveTLS()
                    }
                }
            }
        )
    }

    private func scheduleReceive() {
        guard !receiveInFlight, !completed else { return }
        receiveInFlight = true
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.stateQueue.async {
                self.receiveInFlight = false
                if let error {
                    self.finish(.failure(error))
                    return
                }
                if let data, !data.isEmpty {
                    self.consumeNetworkData(data)
                }
                if isComplete {
                    self.bio.inputEOF = true
                }
                if self.phase == .tls {
                    self.driveTLS()
                }
                if isComplete, !self.completed {
                    self.finish(.success(self.response))
                } else {
                    self.scheduleReceive()
                }
            }
        }
    }

    private func consumeNetworkData(_ data: Data) {
        if phase == .waitingForConnectResponse {
            connectInput.append(data)
            guard let delimiter = connectInput.range(of: Data("\r\n\r\n".utf8))
            else {
                return
            }
            let head = connectInput[..<delimiter.upperBound]
            guard String(data: head, encoding: .utf8)?
                .hasPrefix("HTTP/1.1 200") == true
            else {
                finish(.failure(ClientError.invalidConnectResponse))
                return
            }
            let tlsBytes = connectInput[delimiter.upperBound...]
            if !tlsBytes.isEmpty {
                bio.input.append(tlsBytes)
            }
            connectInput.removeAll(keepingCapacity: false)
            phase = .tls
        } else if phase == .tls {
            bio.input.append(data)
        }
    }

    private func driveTLS() {
        guard phase == .tls, !completed else { return }
        do {
            if !tlsOpen {
                for _ in 0..<8 where !tlsOpen {
                    let status = SSLHandshake(context)
                    if status == errSSLPeerAuthCompleted {
                        try evaluateTrust()
                    } else if status == errSecSuccess {
                        tlsOpen = true
                        if !didNotifyTLSOpen {
                            didNotifyTLSOpen = true
                            onTLSOpen?()
                        }
                    } else if status != errSSLWouldBlock {
                        throw ClientError.tls(status)
                    } else {
                        break
                    }
                }
            }
            if tlsOpen {
                try writeRequest()
                try readResponse()
            }
            flushEncryptedOutput()
        } catch {
            finish(.failure(error))
        }
    }

    private func evaluateTrust() throws {
        var optionalTrust: SecTrust?
        guard SSLCopyPeerTrust(context, &optionalTrust) == errSecSuccess,
              let trust = optionalTrust,
              SecTrustSetAnchorCertificates(
                  trust,
                  [rootCertificate] as CFArray
              ) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else {
            throw ClientError.trust
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw ClientError.trust
        }
    }

    private func writeRequest() throws {
        for _ in 0..<16 where requestOffset < request.count {
            let remaining = Data(request.dropFirst(requestOffset))
            var processed = 0
            let status = remaining.withUnsafeBytes {
                SSLWrite(context, $0.baseAddress, $0.count, &processed)
            }
            guard status == errSecSuccess || status == errSSLWouldBlock else {
                throw ClientError.tls(status)
            }
            requestOffset += processed
            if processed == 0 { return }
        }
    }

    private func readResponse() throws {
        for _ in 0..<32 {
            var plaintext = Data(count: 64 * 1024)
            var processed = 0
            let status = plaintext.withUnsafeMutableBytes {
                SSLRead(context, $0.baseAddress!, $0.count, &processed)
            }
            plaintext.count = processed
            response.append(plaintext)
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
                finish(.success(response))
                return
            }
            guard status == errSecSuccess || status == errSSLWouldBlock else {
                throw ClientError.tls(status)
            }
            if processed == 0 { return }
        }
    }

    private func flushEncryptedOutput() {
        guard !sendInFlight, !bio.output.isEmpty, !completed else { return }
        let ciphertext = bio.output
        bio.output.removeAll(keepingCapacity: true)
        sendInFlight = true
        connection.send(
            content: ciphertext,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.stateQueue.async {
                    self.sendInFlight = false
                    if let error {
                        self.finish(.failure(error))
                    } else {
                        self.driveTLS()
                    }
                }
            }
        )
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        phase = .finished
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ClientError.setup(status)
        }
    }
}

final class LocalProxyIntegrationTests: XCTestCase {
    func testMitmDomainMatchingDoesNotAcceptSuffixSpoofing() {
        let proxy = LocalProxyServer()
        XCTAssertTrue(proxy.isMitmHost("kancolle-server.com"))
        XCTAssertTrue(proxy.isMitmHost("W00G.KANCOLLE-SERVER.COM."))
        XCTAssertFalse(proxy.isMitmHost("evilkancolle-server.com"))
        XCTAssertFalse(proxy.isMitmHost(".kancolle-server.com"))
        XCTAssertFalse(proxy.isMitmHost("kancolle-server.com.example.org"))
        XCTAssertTrue(proxy.isInspectableHost("w00g.kancolle-server.com", 443))
    }

    private var proxy: LocalProxyServer?
    private var services: [String] = []
    private var tlsClients: [ProxyTLSClient] = []

    override func tearDown() {
        proxy?.stop()
        proxy = nil
        tlsClients.removeAll()
        services.forEach {
            MitmCA.deleteStoredMaterial(keychainService: $0)
        }
        services.removeAll()
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

    private func startEchoUpstream(counter: Counter) throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            counter.inc()
            connection.start(queue: .global())
            func receive() {
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 64 * 1024
                ) { data, _, isComplete, error in
                    guard error == nil, let data, !data.isEmpty else {
                        connection.cancel()
                        return
                    }
                    var response = Data("ECHO:".utf8)
                    response.append(data)
                    connection.send(
                        content: response,
                        completion: .contentProcessed { sendError in
                            if sendError != nil || isComplete {
                                connection.cancel()
                            } else {
                                receive()
                            }
                        }
                    )
                }
            }
            receive()
        }
        listener.start(queue: .global())
        return listener
    }

    private func makeCA() throws -> (MitmCA, SecCertificate) {
        let service = "test.KanColle.Game.proxy.\(UUID().uuidString)"
        services.append(service)
        let certificateAuthority = MitmCA(keychainService: service)
        let rootDER = try certificateAuthority.rootCertificateDER()
        let root = try XCTUnwrap(
            SecCertificateCreateWithData(nil, rootDER as CFData)
        )
        return (certificateAuthority, root)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
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

    func testMitmConnectDecryptsAndUsesLocalResourceHandler() throws {
        let host = "w00g.kancolle-server.com"
        let (certificateAuthority, rootCertificate) = try makeCA()
        let proxy = LocalProxyServer()
        self.proxy = proxy
        proxy.mitmCA = certificateAuthority
        let callbackCount = Counter()
        proxy.onGameResourceRequest = { head in
            callbackCount.inc()
            XCTAssertEqual(head.method, "POST")
            XCTAssertEqual(head.path, "/kcs2/js/main.js")
            return ResourceResponse(
                statusCode: 200,
                headers: [("Content-Type", "application/javascript")],
                body: Data("patched-main".utf8)
            )
        }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let finished = expectation(description: "MITM client finished")
        let result = Box<Result<Data, Error>?>(nil)
        let request = Data(
            (
                "POST /kcs2/js/main.js HTTP/1.1\r\n"
                    + "Host: \(host)\r\n"
                    + "Content-Length: 7\r\n\r\n"
                    + "ignored"
            ).utf8
        )
        let client = try ProxyTLSClient(
            proxyPort: proxyPort,
            host: host,
            rootCertificate: rootCertificate,
            request: request
        ) {
            result.set($0)
            finished.fulfill()
        }
        tlsClients.append(client)
        client.start()
        wait(for: [finished], timeout: 10)

        switch try XCTUnwrap(result.value) {
        case .success(let data):
            let response = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(response.contains("200 OK"))
            XCTAssertTrue(response.hasSuffix("patched-main"))
        case .failure(let error):
            XCTFail("MITM request failed: \(error)")
        }
        XCTAssertEqual(callbackCount.value, 1)
        XCTAssertTrue(waitUntil { proxy.activeMitmSessionCount == 0 })
    }

    func testMitmConnectPreservesClientHelloInParserLeftover() throws {
        let host = "w01y.kancolle-server.com"
        let (certificateAuthority, rootCertificate) = try makeCA()
        let proxy = LocalProxyServer()
        self.proxy = proxy
        proxy.mitmCA = certificateAuthority
        proxy.onGameResourceRequest = { _ in
            ResourceResponse(
                statusCode: 200,
                headers: [("Content-Type", "text/plain")],
                body: Data("leftover-ok".utf8)
            )
        }
        let leftoverCount = Box<Int?>(nil)
        proxy.onMitmSessionStarted = { leftoverCount.set($0) }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let finished = expectation(description: "coalesced TLS client finished")
        let result = Box<Result<Data, Error>?>(nil)
        let client = try ProxyTLSClient(
            proxyPort: proxyPort,
            host: host,
            rootCertificate: rootCertificate,
            request: Data(
                "GET /kcs2/img/test.png HTTP/1.1\r\nHost: \(host)\r\n\r\n"
                    .utf8
            ),
            coalesceClientHelloWithConnect: true
        ) {
            result.set($0)
            finished.fulfill()
        }
        tlsClients.append(client)
        client.start()
        wait(for: [finished], timeout: 10)

        switch try XCTUnwrap(result.value) {
        case .success(let data):
            XCTAssertTrue(
                String(data: data, encoding: .utf8)?
                    .contains("leftover-ok") == true
            )
        case .failure(let error):
            XCTFail("coalesced MITM request failed: \(error)")
        }
        XCTAssertGreaterThan(
            try XCTUnwrap(leftoverCount.value),
            0,
            "CONNECT 头后同包到达的 ClientHello 必须交给 MitmSession"
        )
    }

    func testNilMitmCAFallsBackToBlindTunnel() throws {
        let upstreamCounter = Counter()
        let upstream = try startEchoUpstream(counter: upstreamCounter)
        defer { upstream.cancel() }
        let upstreamPort = waitPort { upstream.port?.rawValue ?? 0 }
        XCTAssertNotEqual(upstreamPort, 0)

        let proxy = LocalProxyServer()
        self.proxy = proxy
        proxy.mitmCA = nil
        proxy.tunnelConnectionFactory = { _, _ in
            NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: upstreamPort)!,
                using: .tcp
            )
        }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let response = roundTrip(
            port: proxyPort,
            chunks: [
                "CONNECT w00g.kancolle-server.com:443 HTTP/1.1\r\n\r\n",
                "nil-ca"
            ],
            marker: "ECHO:nil-ca"
        )
        XCTAssertTrue(response?.contains("200 Connection Established") == true)
        XCTAssertTrue(response?.contains("ECHO:nil-ca") == true)
        XCTAssertEqual(upstreamCounter.value, 1)
        XCTAssertEqual(proxy.activeMitmSessionCount, 0)
    }

    func testNonGameDomainIsNeverDecrypted() throws {
        let upstreamCounter = Counter()
        let upstream = try startEchoUpstream(counter: upstreamCounter)
        defer { upstream.cancel() }
        let upstreamPort = waitPort { upstream.port?.rawValue ?? 0 }
        XCTAssertNotEqual(upstreamPort, 0)
        let (certificateAuthority, _) = try makeCA()

        let proxy = LocalProxyServer()
        self.proxy = proxy
        proxy.mitmCA = certificateAuthority
        proxy.tunnelConnectionFactory = { _, _ in
            NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: upstreamPort)!,
                using: .tcp
            )
        }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let response = roundTrip(
            port: proxyPort,
            chunks: [
                "CONNECT evilkancolle-server.com:443 HTTP/1.1\r\n\r\n",
                "not-decrypted"
            ],
            marker: "ECHO:not-decrypted"
        )
        XCTAssertTrue(response?.contains("ECHO:not-decrypted") == true)
        XCTAssertEqual(upstreamCounter.value, 1)
        XCTAssertEqual(proxy.activeMitmSessionCount, 0)
    }

    func testStopCancelsAndReclaimsActiveMitmSessionOnce() throws {
        let host = "w00g.kancolle-server.com"
        let (certificateAuthority, rootCertificate) = try makeCA()
        let proxy = LocalProxyServer()
        self.proxy = proxy
        proxy.mitmCA = certificateAuthority
        let closeCount = Counter()
        proxy.onMitmSessionClosed = { _ in closeCount.inc() }
        try proxy.start()
        let proxyPort = waitPort { proxy.port }
        XCTAssertNotEqual(proxyPort, 0)

        let tlsOpened = expectation(description: "MITM TLS opened")
        let clientClosed = expectation(description: "client closed by stop")
        clientClosed.assertForOverFulfill = true
        let client = try ProxyTLSClient(
            proxyPort: proxyPort,
            host: host,
            rootCertificate: rootCertificate,
            request: Data(),
            onTLSOpen: { tlsOpened.fulfill() }
        ) { _ in
            clientClosed.fulfill()
        }
        tlsClients.append(client)
        client.start()
        wait(for: [tlsOpened], timeout: 10)
        XCTAssertTrue(waitUntil { proxy.activeMitmSessionCount == 1 })

        proxy.stop()
        wait(for: [clientClosed], timeout: 5)
        XCTAssertEqual(proxy.activeMitmSessionCount, 0)
        XCTAssertTrue(waitUntil { closeCount.value == 1 })
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(closeCount.value, 1)
    }

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
