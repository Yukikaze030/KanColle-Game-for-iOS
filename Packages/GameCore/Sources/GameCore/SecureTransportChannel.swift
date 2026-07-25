import Foundation
import Security
import Security.SecureTransport

private final class SecureTransportMemoryBIO {
    private var encryptedInput = Data()
    private var inputOffset = 0
    private var encryptedOutput = Data()
    private var outputOffset = 0

    let outputHighWatermark: Int
    var inputEOF = false
    var outputClosed = false

    init(outputHighWatermark: Int) {
        self.outputHighWatermark = outputHighWatermark
    }

    var inputCount: Int {
        encryptedInput.count - inputOffset
    }

    var outputCount: Int {
        encryptedOutput.count - outputOffset
    }

    var outputCapacity: Int {
        max(0, outputHighWatermark - outputCount)
    }

    func appendInput(_ data: Data) {
        encryptedInput.append(data)
    }

    func readInput(into destination: UnsafeMutableRawPointer, maximumLength: Int) -> Int {
        let count = min(maximumLength, inputCount)
        guard count > 0 else {
            return 0
        }

        encryptedInput.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            destination.copyMemory(
                from: baseAddress.advanced(by: inputOffset),
                byteCount: count
            )
        }
        inputOffset += count
        compactInputIfNeeded()
        return count
    }

    func appendOutput(_ source: UnsafeRawPointer, maximumLength: Int) -> Int {
        guard !outputClosed, maximumLength > 0 else {
            return 0
        }
        let capacity = outputCapacity
        let accepted = min(maximumLength, capacity)
        if accepted > 0 {
            encryptedOutput.append(
                source.assumingMemoryBound(to: UInt8.self),
                count: accepted
            )
        }
        return accepted
    }

    func drainOutput(maximumLength: Int) -> Data {
        let count = min(maximumLength, outputCount)
        guard count > 0 else {
            return Data()
        }
        let start = encryptedOutput.index(
            encryptedOutput.startIndex,
            offsetBy: outputOffset
        )
        let end = encryptedOutput.index(start, offsetBy: count)
        let result = Data(encryptedOutput[start..<end])
        outputOffset += count
        compactOutputIfNeeded()
        return result
    }

    private func compactInputIfNeeded() {
        if inputOffset == encryptedInput.count {
            encryptedInput.removeAll(keepingCapacity: true)
            inputOffset = 0
        } else if inputOffset >= 64 * 1024, inputOffset * 2 >= encryptedInput.count {
            encryptedInput.removeFirst(inputOffset)
            inputOffset = 0
        }
    }

    private func compactOutputIfNeeded() {
        if outputOffset == encryptedOutput.count {
            encryptedOutput.removeAll(keepingCapacity: true)
            outputOffset = 0
        } else if outputOffset >= 64 * 1024,
                  outputOffset * 2 >= encryptedOutput.count
        {
            encryptedOutput.removeFirst(outputOffset)
            outputOffset = 0
        }
    }
}

private let secureTransportReadCallback: SSLReadFunc = {
    connection,
    destination,
    requestedLength in

    let bio = Unmanaged<SecureTransportMemoryBIO>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    let requested = requestedLength.pointee
    let copied = bio.readInput(into: destination, maximumLength: requested)
    requestedLength.pointee = copied

    if copied == requested {
        return errSecSuccess
    }
    if copied > 0 {
        return errSSLWouldBlock
    }
    return bio.inputEOF ? errSSLClosedGraceful : errSSLWouldBlock
}

private let secureTransportWriteCallback: SSLWriteFunc = {
    connection,
    source,
    requestedLength in

    let bio = Unmanaged<SecureTransportMemoryBIO>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    let requested = requestedLength.pointee
    guard !bio.outputClosed else {
        requestedLength.pointee = 0
        return errSSLClosedAbort
    }

    let accepted = bio.appendOutput(source, maximumLength: requested)
    requestedLength.pointee = accepted
    return accepted == requested ? errSecSuccess : errSSLWouldBlock
}

/// A server-side SecureTransport TLS channel backed only by in-memory queues.
///
/// This type performs no network I/O and never waits. Callers append encrypted
/// bytes received asynchronously, drive one SecureTransport operation, and
/// drain encrypted output for asynchronous sending. `errSSLWouldBlock` is a
/// normal result whenever either in-memory queue needs more input or capacity.
///
/// All methods and properties must be accessed serially from one caller-owned
/// execution context. SecureTransport invokes the BIO callbacks synchronously
/// within these methods, so the queues require no locks.
public final class SecureTransportChannel {
    /// Minimum ciphertext capacity required to hold one complete TLS 1.2
    /// record, including the protocol's maximum record expansion allowance.
    ///
    /// TLS 1.2 permits 16 KiB plaintext records plus up to 2 KiB expansion,
    /// including CBC padding and SHA-384 MAC data. 32 KiB stays well above
    /// that complete-record bound and prevents a permanently partial BIO write.
    public static let minimumOutputHighWatermark = 32 * 1024
    private static let maximumTLS12PlaintextRecordLength = 16 * 1024
    private static let maximumTLS12RecordExpansion = 2 * 1024

    public enum State: Equatable {
        case handshaking
        case open
        case peerClosed
        case closing
        case closed
        case failed(OSStatus)
    }

    public enum Progress: Equatable {
        case wouldBlock
        case complete
    }

    public enum ChannelError: Error, Equatable {
        case invalidConfiguration
        case invalidState(State)
        case invalidLength
        case encryptedInputOverflow
        case tls(OSStatus)
    }

    public private(set) var state: State = .handshaking

    public var bufferedEncryptedInputBytes: Int {
        bio.inputCount
    }

    public var bufferedEncryptedOutputBytes: Int {
        bio.outputCount
    }

    private let context: SSLContext
    private let bio: SecureTransportMemoryBIO
    // SSLSetCertificate does not document ownership strongly enough to rely on
    // it for the lifetime of identity/certificates, so retain the exact array.
    private let certificateChain: CFArray
    private let encryptedInputHighWatermark: Int

    public init(
        certificateChain: CFArray,
        outputHighWatermark: Int = 512 * 1024,
        encryptedInputHighWatermark: Int = 1024 * 1024
    ) throws {
        guard outputHighWatermark >= Self.minimumOutputHighWatermark,
              encryptedInputHighWatermark > 0
        else {
            throw ChannelError.invalidConfiguration
        }
        guard let context = SSLCreateContext(nil, .serverSide, .streamType) else {
            throw ChannelError.invalidConfiguration
        }

        self.context = context
        self.bio = SecureTransportMemoryBIO(
            outputHighWatermark: outputHighWatermark
        )
        self.certificateChain = certificateChain
        self.encryptedInputHighWatermark = encryptedInputHighWatermark

        try Self.requireSuccess(
            SSLSetIOFuncs(
                context,
                secureTransportReadCallback,
                secureTransportWriteCallback
            )
        )
        let connection = UnsafeRawPointer(Unmanaged.passUnretained(bio).toOpaque())
        try Self.requireSuccess(SSLSetConnection(context, connection))
        try Self.requireSuccess(SSLSetCertificate(context, certificateChain))
        try Self.requireSuccess(
            SSLSetProtocolVersionMin(context, .tlsProtocol12)
        )
        try Self.requireSuccess(
            SSLSetProtocolVersionMax(context, .tlsProtocol12)
        )
        try Self.requireSuccess(
            SSLSetALPNProtocols(context, ["http/1.1"] as CFArray)
        )
    }

    /// Appends ciphertext obtained from the client-side transport.
    public func receiveEncrypted(_ data: Data) throws {
        guard !data.isEmpty else {
            return
        }
        guard state != .closed else {
            throw ChannelError.invalidState(state)
        }
        guard data.count <= encryptedInputHighWatermark - bio.inputCount else {
            throw ChannelError.encryptedInputOverflow
        }
        bio.appendInput(data)
    }

    /// Marks the encrypted input stream as ended.
    ///
    /// A later handshake/read operation returns a TLS close status instead of
    /// repeatedly requesting bytes that can no longer arrive.
    public func markEncryptedInputEOF() {
        bio.inputEOF = true
    }

    /// Performs at most one `SSLHandshake` call.
    ///
    /// There is deliberately no retry loop: after `.wouldBlock`, the caller
    /// must first provide input or drain output and schedule another drive.
    @discardableResult
    public func driveHandshake() throws -> Progress {
        if state == .open {
            return .complete
        }
        guard state == .handshaking else {
            throw ChannelError.invalidState(state)
        }

        let status = SSLHandshake(context)
        switch status {
        case errSecSuccess:
            state = .open
            return .complete
        case errSSLWouldBlock:
            return .wouldBlock
        case errSSLClosedGraceful, errSSLClosedNoNotify:
            state = .peerClosed
            return .complete
        default:
            try fail(status)
        }
    }

    /// Decrypts up to `maxLength` bytes.
    ///
    /// An empty result while the state remains `.open` means would-block.
    public func readPlaintext(maxLength: Int = 64 * 1024) throws -> Data {
        guard maxLength > 0 else {
            throw ChannelError.invalidLength
        }
        guard state == .open || state == .closing else {
            if state == .peerClosed || state == .closed {
                return Data()
            }
            throw ChannelError.invalidState(state)
        }

        var plaintext = Data(count: maxLength)
        var processed = 0
        let status = plaintext.withUnsafeMutableBytes { bytes in
            SSLRead(context, bytes.baseAddress!, bytes.count, &processed)
        }
        plaintext.count = processed

        switch status {
        case errSecSuccess, errSSLWouldBlock:
            return plaintext
        case errSSLClosedGraceful, errSSLClosedNoNotify:
            state = state == .closing ? .closed : .peerClosed
            return plaintext
        default:
            try fail(status)
        }
    }

    /// Encrypts as much plaintext as the output high-watermark permits.
    ///
    /// The returned count may be smaller than `data.count`, including zero.
    /// Drain encrypted output before retrying the unconsumed suffix.
    @discardableResult
    public func writePlaintext(_ data: Data) throws -> Int {
        guard state == .open else {
            throw ChannelError.invalidState(state)
        }
        guard !data.isEmpty else {
            return 0
        }

        // SecureTransport can report all plaintext as processed even when its
        // write callback accepted only part of the resulting TLS record. RFC
        // 5246 permits 16 KiB plaintext plus 2 KiB record expansion. Limit one
        // SSLWrite to a single complete record and reserve the full expansion,
        // including CBC padding and SHA-384 MACs, before entering the engine.
        let writablePlaintext = min(
            data.count,
            Self.maximumTLS12PlaintextRecordLength,
            max(0, bio.outputCapacity - Self.maximumTLS12RecordExpansion)
        )
        guard writablePlaintext > 0 else {
            return 0
        }

        var processed = 0
        let status = data.withUnsafeBytes { bytes in
            SSLWrite(context, bytes.baseAddress, writablePlaintext, &processed)
        }
        switch status {
        case errSecSuccess, errSSLWouldBlock:
            return processed
        case errSSLClosedGraceful, errSSLClosedNoNotify:
            state = .peerClosed
            return processed
        default:
            try fail(status)
        }
    }

    /// Removes ciphertext produced by the TLS engine.
    public func drainEncryptedOutput(maxLength: Int = .max) -> Data {
        guard maxLength > 0 else {
            return Data()
        }
        return bio.drainOutput(maximumLength: maxLength)
    }

    /// Starts or resumes an orderly TLS shutdown.
    ///
    /// If the output queue is full this returns `.wouldBlock`; drain it and
    /// invoke `close()` again to let SecureTransport finish `close_notify`.
    @discardableResult
    public func close() throws -> Progress {
        if state == .closed {
            return .complete
        }
        guard state == .open || state == .peerClosed || state == .closing else {
            throw ChannelError.invalidState(state)
        }

        state = .closing
        let status = SSLClose(context)
        switch status {
        case errSecSuccess, errSSLClosedGraceful, errSSLClosedNoNotify:
            state = .closed
            return .complete
        case errSSLWouldBlock:
            return .wouldBlock
        default:
            try fail(status)
        }
    }

    deinit {
        bio.outputClosed = true
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ChannelError.tls(status)
        }
    }

    private func fail(_ status: OSStatus) throws -> Never {
        state = .failed(status)
        throw ChannelError.tls(status)
    }
}
