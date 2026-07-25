import Foundation
import Security
import Security.SecureTransport
import XCTest
@testable import GameCore

private final class ClientMemoryBIO {
    var encryptedInput = Data()
    var encryptedOutput = Data()
    var inputEOF = false
}

private let clientReadCallback: SSLReadFunc = { connection, destination, requestedLength in
    let bio = Unmanaged<ClientMemoryBIO>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    let requested = requestedLength.pointee
    let copied = min(requested, bio.encryptedInput.count)
    if copied > 0 {
        bio.encryptedInput.copyBytes(
            to: destination.assumingMemoryBound(to: UInt8.self),
            count: copied
        )
        bio.encryptedInput.removeFirst(copied)
    }
    requestedLength.pointee = copied
    if copied == requested {
        return errSecSuccess
    }
    if copied > 0 {
        return errSSLWouldBlock
    }
    return bio.inputEOF ? errSSLClosedGraceful : errSSLWouldBlock
}

private let clientWriteCallback: SSLWriteFunc = { connection, source, requestedLength in
    let bio = Unmanaged<ClientMemoryBIO>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    let count = requestedLength.pointee
    if count > 0 {
        bio.encryptedOutput.append(source.assumingMemoryBound(to: UInt8.self), count: count)
    }
    return errSecSuccess
}

private final class SecureTransportClient {
    enum ClientError: Error {
        case setup(OSStatus)
        case trust(OSStatus)
        case untrusted
        case tls(OSStatus)
    }

    let context: SSLContext
    let bio = ClientMemoryBIO()
    private let rootCertificate: SecCertificate
    private(set) var isOpen = false
    private(set) var receivedCloseNotify = false

    init(host: String, rootCertificate: SecCertificate) throws {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw ClientError.setup(errSecAllocate)
        }
        self.context = context
        self.rootCertificate = rootCertificate

        try Self.check(SSLSetIOFuncs(context, clientReadCallback, clientWriteCallback))
        let connection = UnsafeRawPointer(Unmanaged.passUnretained(bio).toOpaque())
        try Self.check(SSLSetConnection(context, connection))
        try Self.check(SSLSetProtocolVersionMin(context, .tlsProtocol12))
        try Self.check(SSLSetProtocolVersionMax(context, .tlsProtocol12))
        try Self.check(SSLSetSessionOption(context, .breakOnServerAuth, true))
        try host.utf8CString.withUnsafeBytes { bytes in
            try Self.check(
                SSLSetPeerDomainName(context, bytes.baseAddress, host.utf8.count)
            )
        }
    }

    func driveHandshake() throws {
        guard !isOpen else { return }
        let status = SSLHandshake(context)
        if status == errSSLPeerAuthCompleted {
            var trust: SecTrust?
            try Self.check(SSLCopyPeerTrust(context, &trust), trustError: true)
            guard let trust else {
                throw ClientError.untrusted
            }
            try Self.check(
                SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray),
                trustError: true
            )
            try Self.check(
                SecTrustSetAnchorCertificatesOnly(trust, true),
                trustError: true
            )
            var error: CFError?
            guard SecTrustEvaluateWithError(trust, &error) else {
                throw ClientError.untrusted
            }
            return
        }
        if status == errSecSuccess {
            isOpen = true
            return
        }
        guard status == errSSLWouldBlock else {
            throw ClientError.tls(status)
        }
    }

    func receiveEncrypted(_ data: Data) {
        bio.encryptedInput.append(data)
    }

    func drainEncrypted(maxLength: Int = .max) -> Data {
        let count = min(maxLength, bio.encryptedOutput.count)
        let result = Data(bio.encryptedOutput.prefix(count))
        bio.encryptedOutput.removeFirst(count)
        return result
    }

    func writePlaintext(_ data: Data) throws -> Int {
        var processed = 0
        let status = data.withUnsafeBytes { bytes in
            SSLWrite(context, bytes.baseAddress, bytes.count, &processed)
        }
        guard status == errSecSuccess || status == errSSLWouldBlock else {
            throw ClientError.tls(status)
        }
        return processed
    }

    func readPlaintext(maxLength: Int = 64 * 1024) throws -> Data {
        var buffer = Data(count: maxLength)
        var processed = 0
        let status = buffer.withUnsafeMutableBytes { bytes in
            SSLRead(context, bytes.baseAddress!, bytes.count, &processed)
        }
        if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
            receivedCloseNotify = status == errSSLClosedGraceful
            return Data()
        }
        guard status == errSecSuccess || status == errSSLWouldBlock else {
            throw ClientError.tls(status)
        }
        buffer.count = processed
        return buffer
    }

    @discardableResult
    func close() throws -> OSStatus {
        let status = SSLClose(context)
        guard status == errSecSuccess || status == errSSLWouldBlock else {
            throw ClientError.tls(status)
        }
        return status
    }

    private static func check(_ status: OSStatus, trustError: Bool = false) throws {
        guard status == errSecSuccess else {
            if trustError {
                throw ClientError.trust(status)
            }
            throw ClientError.setup(status)
        }
    }
}

final class SecureTransportChannelTests: XCTestCase {
    private struct Pair {
        let service: String
        let server: SecureTransportChannel
        let client: SecureTransportClient
    }

    private func makePair(outputHighWatermark: Int = 512 * 1024) throws -> Pair {
        let service = "test.KanColle.Game.channel.\(UUID().uuidString)"
        addTeardownBlock {
            MitmCA.deleteStoredMaterial(keychainService: service)
        }

        let host = "w00g.kancolle-server.com"
        let ca = MitmCA(keychainService: service)
        let issued = try ca.issueCertificate(forHost: host)
        let rootDER = try ca.rootCertificateDER()
        let leaf = try XCTUnwrap(
            SecCertificateCreateWithData(nil, issued.certificateDER as CFData)
        )
        let root = try XCTUnwrap(
            SecCertificateCreateWithData(nil, rootDER as CFData)
        )
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2_048,
            kSecAttrIsPermanent: false
        ]
        var keyError: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(
            SecKeyCreateWithData(
                issued.privateKeyDER as CFData,
                keyAttributes as CFDictionary,
                &keyError
            )
        )
        XCTAssertNil(keyError?.takeRetainedValue())
        let identity = try XCTUnwrap(SecIdentityCreate(nil, leaf, privateKey))
        let chain = [identity, root] as CFArray

        return try Pair(
            service: service,
            server: SecureTransportChannel(
                certificateChain: chain,
                outputHighWatermark: outputHighWatermark
            ),
            client: SecureTransportClient(host: host, rootCertificate: root)
        )
    }

    private func handshake(
        _ pair: Pair,
        clientFragment: Int = .max,
        serverFragment: Int = .max
    ) throws {
        for _ in 0..<40_000 {
            try pair.client.driveHandshake()
            let clientBytes = pair.client.drainEncrypted(maxLength: clientFragment)
            if !clientBytes.isEmpty {
                try pair.server.receiveEncrypted(clientBytes)
            }

            _ = try pair.server.driveHandshake()
            let serverBytes = pair.server.drainEncryptedOutput(maxLength: serverFragment)
            if !serverBytes.isEmpty {
                pair.client.receiveEncrypted(serverBytes)
            }

            if pair.client.isOpen, pair.server.state == .open {
                return
            }
        }
        XCTFail("TLS handshake did not complete")
    }

    private func transferClientOutput(
        _ pair: Pair,
        fragmentSize: Int = .max
    ) throws {
        while pair.client.bio.encryptedOutput.count > 0 {
            try pair.server.receiveEncrypted(
                pair.client.drainEncrypted(maxLength: fragmentSize)
            )
        }
    }

    func testOneByteFragmentedHandshake() throws {
        let pair = try makePair()

        try handshake(pair, clientFragment: 1, serverFragment: 1)

        XCTAssertEqual(pair.server.state, .open)
        XCTAssertTrue(pair.client.isOpen)
    }

    func testHandshakeAndPlaintextWouldBlockDoNotBusyLoop() throws {
        let pair = try makePair()

        XCTAssertEqual(try pair.server.driveHandshake(), .wouldBlock)
        XCTAssertEqual(try pair.server.driveHandshake(), .wouldBlock)
        XCTAssertEqual(pair.server.bufferedEncryptedOutputBytes, 0)

        try handshake(pair)
        XCTAssertEqual(try pair.server.readPlaintext(), Data())
        XCTAssertEqual(pair.server.state, .open)
    }

    func testHTTPPlaintextFlowsInBothDirections() throws {
        let pair = try makePair()
        try handshake(pair, clientFragment: 7, serverFragment: 13)

        let request = Data("GET /kcsapi/api_start2 HTTP/1.1\r\nHost: w00g.kancolle-server.com\r\n\r\n".utf8)
        XCTAssertEqual(try pair.client.writePlaintext(request), request.count)
        try transferClientOutput(pair, fragmentSize: 5)

        var decryptedRequest = Data()
        for _ in 0..<100 {
            let part = try pair.server.readPlaintext(maxLength: 11)
            if part.isEmpty { break }
            decryptedRequest.append(part)
        }
        XCTAssertEqual(decryptedRequest, request)

        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8)
        var written = 0
        while written < response.count {
            written += try pair.server.writePlaintext(Data(response.dropFirst(written)))
            let encrypted = pair.server.drainEncryptedOutput()
            if !encrypted.isEmpty {
                pair.client.receiveEncrypted(encrypted)
            }
        }

        var decryptedResponse = Data()
        for _ in 0..<100 {
            let part = try pair.client.readPlaintext(maxLength: 9)
            if part.isEmpty { break }
            decryptedResponse.append(part)
        }
        XCTAssertEqual(decryptedResponse, response)
    }

    func testPartialEncryptedInputReturnsWouldBlockUntilRecordCompletes() throws {
        let pair = try makePair()
        try handshake(pair)

        let request = Data(repeating: 0x41, count: 8_192)
        XCTAssertEqual(try pair.client.writePlaintext(request), request.count)
        let encrypted = pair.client.drainEncrypted()
        XCTAssertGreaterThan(encrypted.count, request.count)
        let split = encrypted.count / 2

        try pair.server.receiveEncrypted(Data(encrypted.prefix(split)))
        XCTAssertEqual(try pair.server.readPlaintext(maxLength: request.count), Data())

        try pair.server.receiveEncrypted(Data(encrypted.dropFirst(split)))
        var result = Data()
        while result.count < request.count {
            let part = try pair.server.readPlaintext(maxLength: request.count - result.count)
            if part.isEmpty { break }
            result.append(part)
        }
        XCTAssertEqual(result, request)
    }

    func testOutputHighWatermarkCausesPartialWriteAndResumesAfterDrain() throws {
        let pair = try makePair(outputHighWatermark: 2_048)
        try handshake(pair)
        _ = pair.server.drainEncryptedOutput()

        let payload = Data(repeating: 0x5A, count: 64 * 1024)
        var offset = 0
        var received = Data()
        var sawPartialWrite = false

        for _ in 0..<10_000 where offset < payload.count {
            let remaining = Data(payload.dropFirst(offset))
            let accepted = try pair.server.writePlaintext(remaining)
            if accepted < remaining.count {
                sawPartialWrite = true
            }
            offset += accepted
            XCTAssertLessThanOrEqual(pair.server.bufferedEncryptedOutputBytes, 2_048)

            let encrypted = pair.server.drainEncryptedOutput(maxLength: 257)
            if !encrypted.isEmpty {
                pair.client.receiveEncrypted(encrypted)
            }
            let plaintext = try pair.client.readPlaintext(maxLength: 4_096)
            received.append(plaintext)
        }

        while pair.server.bufferedEncryptedOutputBytes > 0 {
            pair.client.receiveEncrypted(pair.server.drainEncryptedOutput(maxLength: 257))
            received.append(try pair.client.readPlaintext(maxLength: 4_096))
        }
        for _ in 0..<100 where received.count < payload.count {
            let part = try pair.client.readPlaintext(maxLength: 4_096)
            if part.isEmpty { break }
            received.append(part)
        }

        XCTAssertTrue(sawPartialWrite)
        XCTAssertEqual(offset, payload.count)
        XCTAssertEqual(received, payload)
    }

    func testCloseProducesCloseNotifyAndTransitionsState() throws {
        let pair = try makePair()
        try handshake(pair)

        _ = try pair.server.close()
        XCTAssertTrue(pair.server.state == .closing || pair.server.state == .closed)
        pair.client.receiveEncrypted(pair.server.drainEncryptedOutput())

        _ = try pair.client.readPlaintext()
        XCTAssertTrue(pair.client.receivedCloseNotify)
        XCTAssertEqual(pair.server.state, .closed)
    }
}
