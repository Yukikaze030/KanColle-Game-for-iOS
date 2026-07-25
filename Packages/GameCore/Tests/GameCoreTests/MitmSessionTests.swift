import Foundation
import Network
import Security
import Security.SecureTransport
import XCTest
@testable import GameCore

private final class SessionClientBIO {
    var input = Data()
    var output = Data()
    var inputEOF = false
}

private let sessionClientRead: SSLReadFunc = {
    connection,
    destination,
    requestedLength in

    let bio = Unmanaged<SessionClientBIO>
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

private let sessionClientWrite: SSLWriteFunc = {
    connection,
    source,
    requestedLength in

    let bio = Unmanaged<SessionClientBIO>
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

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

private final class StubUpstreamTask: MitmUpstreamRequestTask {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) {
        self.onCancel = onCancel
    }
    func cancel() {
        onCancel()
    }
}

private final class StubUpstreamExecutor: MitmUpstreamRequestExecuting {
    struct Call {
        let host: String
        let request: Data
        let responseLimit: Int
        let timeout: TimeInterval
    }

    let calls = LockedBox<[Call]>([])
    var result: Result<Data, Error>

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func execute(
        host: String,
        request: Data,
        responseLimit: Int,
        timeout: TimeInterval,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> MitmUpstreamRequestTask {
        calls.mutate {
            $0.append(
                Call(
                    host: host,
                    request: request,
                    responseLimit: responseLimit,
                    timeout: timeout
                )
            )
        }
        DispatchQueue.global().async {
            completion(self.result)
        }
        return StubUpstreamTask()
    }
}

private final class SessionTLSClient {
    enum ClientError: Error {
        case setup(OSStatus)
        case trust
        case tls(OSStatus)
    }

    private let connection: NWConnection
    private let context: SSLContext
    private let rootCertificate: SecCertificate
    private let requestChunks: [Data]
    private let encryptedFragmentSize: Int
    private let stateQueue = DispatchQueue(
        label: "GameCoreTests.MitmSessionClient"
    )
    private let networkQueue = DispatchQueue(
        label: "GameCoreTests.MitmSessionClient.Network"
    )
    private let bio = SessionClientBIO()
    private var requestChunkIndex = 0
    private var requestChunkOffset = 0
    private var sendInFlight = false
    private var receiveInFlight = false
    private var isOpen = false
    private var completed = false
    private var response = Data()
    private let completion: (Result<Data, Error>) -> Void

    init(
        port: UInt16,
        host: String,
        rootCertificate: SecCertificate,
        requestChunks: [Data],
        encryptedFragmentSize: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) throws {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw ClientError.setup(errSecAllocate)
        }
        self.context = context
        self.rootCertificate = rootCertificate
        self.requestChunks = requestChunks
        self.encryptedFragmentSize = encryptedFragmentSize
        self.completion = completion
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        try Self.check(
            SSLSetIOFuncs(context, sessionClientRead, sessionClientWrite)
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
                    self.drive()
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
        stateQueue.async {
            self.scheduleReceive()
        }
    }

    private func drive() {
        guard !completed else { return }
        do {
            if !isOpen {
                for _ in 0..<8 where !isOpen {
                    let status = SSLHandshake(context)
                    if status == errSSLPeerAuthCompleted {
                        try evaluateTrust()
                    } else if status == errSecSuccess {
                        isOpen = true
                    } else if status != errSSLWouldBlock {
                        throw ClientError.tls(status)
                    } else {
                        break
                    }
                }
            }

            if isOpen {
                try writeRequest()
                try readResponse()
            }
            flushEncrypted()
            scheduleReceive()
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
        for _ in 0..<16 where requestChunkIndex < requestChunks.count {
            let chunk = requestChunks[requestChunkIndex]
            let remaining = Data(chunk.dropFirst(requestChunkOffset))
            var processed = 0
            let status = remaining.withUnsafeBytes {
                SSLWrite(
                    context,
                    $0.baseAddress,
                    $0.count,
                    &processed
                )
            }
            guard status == errSecSuccess || status == errSSLWouldBlock else {
                throw ClientError.tls(status)
            }
            requestChunkOffset += processed
            if requestChunkOffset == chunk.count {
                requestChunkIndex += 1
                requestChunkOffset = 0
            }
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

    private func flushEncrypted() {
        guard !sendInFlight, !bio.output.isEmpty, !completed else { return }
        let count = min(encryptedFragmentSize, bio.output.count)
        let ciphertext = Data(bio.output.prefix(count))
        bio.output.removeFirst(count)
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
                        self.drive()
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
                if let data, !data.isEmpty {
                    self.bio.input.append(data)
                }
                if isComplete {
                    self.bio.inputEOF = true
                }
                if let error {
                    self.finish(.failure(error))
                } else {
                    self.drive()
                    if isComplete, !self.completed {
                        self.finish(.success(self.response))
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
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

final class MitmSessionTests: XCTestCase {
    private let host = "w00g.kancolle-server.com"
    private var listeners: [NWListener] = []
    private var sessions: [MitmSession] = []
    private var services: [String] = []

    override func tearDown() {
        listeners.forEach { $0.cancel() }
        sessions.forEach { $0.cancel() }
        services.forEach {
            MitmCA.deleteStoredMaterial(keychainService: $0)
        }
        listeners.removeAll()
        sessions.removeAll()
        services.removeAll()
        super.tearDown()
    }

    private struct RunResult {
        let response: Data
        let closeReasons: LockedBox<[MitmSession.CloseReason]>
    }

    private func runSession(
        requestChunks: [Data],
        encryptedFragmentSize: Int = 7,
        upstream: StubUpstreamExecutor,
        localHandler: MitmSession.LocalResourceHandler? = nil,
        timeout: TimeInterval = 8
    ) throws -> RunResult {
        let service = "test.KanColle.Game.session.\(UUID().uuidString)"
        services.append(service)
        let ca = MitmCA(keychainService: service)
        let material = try MitmIdentityMaterial(
            host: host,
            certificateAuthority: ca
        )
        let listener = try NWListener(using: .tcp, on: .any)
        listeners.append(listener)
        let listenerReady = expectation(description: "listener ready")
        let clientFinished = expectation(description: "TLS client finished")
        let sessionClosed = expectation(description: "session closed")
        let responseBox = LockedBox<Result<Data, Error>?>(nil)
        let closeReasons = LockedBox<[MitmSession.CloseReason]>([])

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerReady.fulfill()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: .global())
            do {
                let session = try MitmSession(
                    clientConnection: connection,
                    host: self.host,
                    identityMaterial: material,
                    upstreamExecutor: upstream,
                    localResourceHandler: localHandler,
                    timeouts: .init(
                        handshake: 3,
                        request: 3,
                        upstream: 3,
                        total: 6
                    )
                )
                session.onClosed = { reason in
                    closeReasons.mutate { $0.append(reason) }
                    sessionClosed.fulfill()
                }
                self.sessions.append(session)
                session.start()
            } catch {
                XCTFail("session setup: \(error)")
            }
        }
        listener.start(queue: .global())
        wait(for: [listenerReady], timeout: timeout)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let client = try SessionTLSClient(
            port: port,
            host: host,
            rootCertificate: material.rootCertificate,
            requestChunks: requestChunks,
            encryptedFragmentSize: encryptedFragmentSize
        ) { result in
            responseBox.set(result)
            clientFinished.fulfill()
        }
        client.start()
        wait(for: [clientFinished, sessionClosed], timeout: timeout)

        switch try XCTUnwrap(responseBox.value) {
        case .success(let response):
            return RunResult(
                response: response,
                closeReasons: closeReasons
            )
        case .failure(let error):
            throw error
        }
    }

    func testFragmentedEncryptedPOSTForwardsOneSanitizedTransaction() throws {
        let upstream = StubUpstreamExecutor(
            result: .success(
                Data(
                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive, X-Drop\r\nX-Drop: secret\r\n\r\nOK"
                        .utf8
                )
            )
        )
        let head = Data(
            (
                "POST /kcsapi/api_start2 HTTP/1.1\r\n"
                    + "Host: \(host)\r\n"
                    + "Content-Length: 11\r\n"
                    + "Connection: keep-alive, Foo\r\n"
                    + "Proxy-Connection: keep-alive\r\n"
                    + "Foo: remove-me\r\n\r\n"
                    + "hello="
            ).utf8
        )
        let result = try runSession(
            requestChunks: [head, Data("world".utf8)],
            encryptedFragmentSize: 1,
            upstream: upstream
        )

        let response = try XCTUnwrap(
            String(data: result.response, encoding: .utf8)
        )
        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.hasSuffix("OK"))
        XCTAssertTrue(response.contains("Connection: close"))
        XCTAssertFalse(response.contains("X-Drop"))
        XCTAssertEqual(result.closeReasons.value, [.completed])

        let call = try XCTUnwrap(upstream.calls.value.first)
        XCTAssertEqual(call.host, host)
        XCTAssertEqual(call.responseLimit, MitmSession.maximumResponseBytes)
        let forwarded = try XCTUnwrap(
            String(data: call.request, encoding: .utf8)
        )
        XCTAssertTrue(forwarded.contains("POST /kcsapi/api_start2 HTTP/1.1"))
        XCTAssertTrue(forwarded.contains("Host: \(host)"))
        XCTAssertTrue(forwarded.contains("Connection: close"))
        XCTAssertFalse(forwarded.contains("Proxy-Connection"))
        XCTAssertFalse(forwarded.contains("Foo: remove-me"))
        XCTAssertTrue(forwarded.hasSuffix("hello=world"))

        sessions.first?.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(result.closeReasons.value, [.completed])
    }

    func testLocalResourceShortCircuitDoesNotReachUpstream() throws {
        let upstream = StubUpstreamExecutor(
            result: .failure(MitmUpstreamError.connectionFailed)
        )
        let result = try runSession(
            requestChunks: [
                Data(
                    "GET /kcs2/js/main.js HTTP/1.1\r\nHost: \(host)\r\n\r\n"
                        .utf8
                )
            ],
            upstream: upstream
        ) { head, body in
            XCTAssertEqual(head.path, "/kcs2/js/main.js")
            XCTAssertTrue(body.isEmpty)
            return ResourceResponse(
                statusCode: 200,
                headers: [("Content-Type", "application/javascript")],
                body: Data("patched".utf8)
            )
        }
        XCTAssertTrue(
            String(data: result.response, encoding: .utf8)?
                .contains("patched") == true
        )
        XCTAssertTrue(upstream.calls.value.isEmpty)
    }

    func testHostMismatchIsRejectedBeforeUpstream() throws {
        let upstream = StubUpstreamExecutor(
            result: .failure(MitmUpstreamError.connectionFailed)
        )
        let result = try runSession(
            requestChunks: [
                Data(
                    "GET / HTTP/1.1\r\nHost: attacker.example:443\r\n\r\n"
                        .utf8
                )
            ],
            upstream: upstream
        )
        XCTAssertTrue(
            String(data: result.response, encoding: .utf8)?
                .contains("400 Bad Request") == true
        )
        XCTAssertTrue(upstream.calls.value.isEmpty)
    }

    func testChunkedRequestIsRejectedWith501() throws {
        let upstream = StubUpstreamExecutor(
            result: .failure(MitmUpstreamError.connectionFailed)
        )
        let result = try runSession(
            requestChunks: [
                Data(
                    (
                        "POST / HTTP/1.1\r\nHost: \(host)\r\n"
                            + "Transfer-Encoding: chunked\r\n\r\n"
                    ).utf8
                )
            ],
            upstream: upstream
        )
        XCTAssertTrue(
            String(data: result.response, encoding: .utf8)?
                .contains("501 Not Implemented") == true
        )
        XCTAssertTrue(upstream.calls.value.isEmpty)
    }

    func testOversizedBodyDeclarationIsRejectedWithoutAllocation() throws {
        let upstream = StubUpstreamExecutor(
            result: .failure(MitmUpstreamError.connectionFailed)
        )
        let result = try runSession(
            requestChunks: [
                Data(
                    (
                        "POST / HTTP/1.1\r\nHost: \(host)\r\nContent-Length: "
                            + "\(MitmSession.maximumRequestBodyBytes + 1)\r\n\r\n"
                    ).utf8
                )
            ],
            upstream: upstream
        )
        XCTAssertTrue(
            String(data: result.response, encoding: .utf8)?
                .contains("400 Bad Request") == true
        )
        XCTAssertTrue(upstream.calls.value.isEmpty)
    }

    func testUpstreamFailureReturns502AndDoesNotDeadlock() throws {
        let upstream = StubUpstreamExecutor(
            result: .failure(MitmUpstreamError.connectionFailed)
        )
        let start = Date()
        let result = try runSession(
            requestChunks: [
                Data(
                    "HEAD /missing HTTP/1.1\r\nHost: \(host):443\r\n\r\n"
                        .utf8
                )
            ],
            encryptedFragmentSize: 1,
            upstream: upstream
        )
        XCTAssertTrue(
            String(data: result.response, encoding: .utf8)?
                .contains("502 Bad Gateway") == true
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 7)
        XCTAssertEqual(result.closeReasons.value, [.completed])
    }
}
