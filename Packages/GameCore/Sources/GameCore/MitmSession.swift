import Foundation
import Network

/// Terminates one client TLS connection after an HTTP CONNECT response and
/// forwards exactly one validated HTTP/1.1 transaction to the fixed origin.
///
/// The supplied `NWConnection` must already be started. All mutable session
/// state and all `SecureTransportChannel` calls are confined to `stateQueue`.
/// Network.framework callbacks only enqueue work onto that queue.
public final class MitmSession: @unchecked Sendable {
    public struct Timeouts: Sendable {
        public var handshake: TimeInterval
        public var request: TimeInterval
        public var upstream: TimeInterval
        public var total: TimeInterval

        public init(
            handshake: TimeInterval = 10,
            request: TimeInterval = 15,
            upstream: TimeInterval = 15,
            total: TimeInterval = 120
        ) {
            self.handshake = handshake
            self.request = request
            self.upstream = upstream
            self.total = total
        }
    }

    public enum State: Equatable {
        case idle
        case handshaking
        case readingRequest
        case waitingForUpstream
        case writingResponse
        case closing
        case closed
    }

    public enum CloseReason: Equatable {
        case completed
        case cancelled
        case clientClosed
        case tlsFailure
        case timeout
        case transportFailure
    }

    public typealias LocalResourceHandler =
        (ProxyHTTPParser.HTTPRequestHead, Data) -> ResourceResponse?

    public static let maximumRequestHeadBytes = 64 * 1024
    public static let maximumRequestBodyBytes = 8 * 1024 * 1024
    public static let maximumResponseBytes = 32 * 1024 * 1024

    public var onClosed: ((CloseReason) -> Void)?

    public private(set) var state: State = .idle

    private enum TimerKind: Hashable {
        case handshake
        case request
        case upstream
        case total
    }

    private let client: NWConnection
    private let outerHost: String
    private let normalizedOuterHost: String
    private let channel: SecureTransportChannel
    private let identityMaterial: MitmIdentityMaterial
    private let upstreamExecutor: MitmUpstreamRequestExecuting
    private let localResourceHandler: LocalResourceHandler?
    private let timeouts: Timeouts
    private let stateQueue: DispatchQueue

    private var parser = ProxyHTTPParser()
    private var requestHeadInputBytes = 0
    private var requestHead: ProxyHTTPParser.HTTPRequestHead?
    private var requestBody = Data()
    private var expectedBodyLength: Int?
    private var receiveInFlight = false
    private var sendInFlight = false
    private var isDriving = false
    private var pendingResponse = Data()
    private var pendingResponseOffset = 0
    private var upstreamTask: MitmUpstreamRequestTask?
    private var timerTokens: [TimerKind: UUID] = [:]
    private var closeCallbackDelivered = false

    public convenience init(
        clientConnection: NWConnection,
        host: String,
        certificateAuthority: MitmCA,
        upstreamExecutor: MitmUpstreamRequestExecuting = NWHTTPSUpstreamClient(),
        localResourceHandler: LocalResourceHandler? = nil,
        timeouts: Timeouts = Timeouts(),
        stateQueue: DispatchQueue? = nil
    ) throws {
        let material = try MitmIdentityMaterial(
            host: host,
            certificateAuthority: certificateAuthority
        )
        try self.init(
            clientConnection: clientConnection,
            host: host,
            identityMaterial: material,
            upstreamExecutor: upstreamExecutor,
            localResourceHandler: localResourceHandler,
            timeouts: timeouts,
            stateQueue: stateQueue
        )
    }

    public init(
        clientConnection: NWConnection,
        host: String,
        identityMaterial: MitmIdentityMaterial,
        upstreamExecutor: MitmUpstreamRequestExecuting = NWHTTPSUpstreamClient(),
        localResourceHandler: LocalResourceHandler? = nil,
        timeouts: Timeouts = Timeouts(),
        stateQueue: DispatchQueue? = nil
    ) throws {
        guard let normalizedHost = Self.normalizeDNSHost(host) else {
            throw MitmUpstreamError.invalidHost
        }
        self.client = clientConnection
        self.outerHost = normalizedHost
        self.normalizedOuterHost = normalizedHost
        self.identityMaterial = identityMaterial
        self.channel = try SecureTransportChannel(
            certificateChain: identityMaterial.certificateChain
        )
        self.upstreamExecutor = upstreamExecutor
        self.localResourceHandler = localResourceHandler
        self.timeouts = timeouts
        self.stateQueue = stateQueue ?? DispatchQueue(
            label: "GameCore.MitmSession.\(UUID().uuidString)",
            qos: .userInitiated
        )
    }

    public func start(initialEncryptedData: Data = Data()) {
        stateQueue.async { [weak self] in
            guard let self, self.state == .idle else { return }
            self.state = .handshaking
            self.client.stateUpdateHandler = { [weak self] connectionState in
                self?.stateQueue.async {
                    self?.handleClientState(connectionState)
                }
            }
            self.arm(.handshake, after: self.timeouts.handshake)
            self.arm(.total, after: self.timeouts.total)
            do {
                try self.channel.receiveEncrypted(initialEncryptedData)
                self.drive()
            } catch {
                self.finish(.tlsFailure)
            }
        }
    }

    public func cancel() {
        stateQueue.async { [weak self] in
            self?.finish(.cancelled)
        }
    }

    private func handleClientState(_ connectionState: NWConnection.State) {
        guard state != .closed else { return }
        switch connectionState {
        case .failed:
            finish(.transportFailure)
        case .cancelled:
            finish(.clientClosed)
        default:
            break
        }
    }

    private func drive() {
        guard !isDriving, state != .closed else { return }
        isDriving = true
        defer {
            isDriving = false
            flushEncryptedOutput()
            scheduleReceiveIfNeeded()
        }

        do {
            switch state {
            case .handshaking:
                _ = try channel.driveHandshake()
                if channel.state == .open {
                    cancelTimer(.handshake)
                    state = .readingRequest
                    arm(.request, after: timeouts.request)
                    try drainRequestPlaintext()
                    if state == .writingResponse {
                        writePendingResponse()
                    }
                } else if channel.state == .peerClosed {
                    finish(.clientClosed)
                }
            case .readingRequest:
                try drainRequestPlaintext()
                if state == .writingResponse {
                    writePendingResponse()
                }
            case .writingResponse:
                writePendingResponse()
            case .closing:
                driveTLSClose()
            case .idle, .waitingForUpstream, .closed:
                break
            }
        } catch {
            finish(.tlsFailure)
        }
    }

    private func drainRequestPlaintext() throws {
        for _ in 0..<32 where state == .readingRequest {
            let plaintext = try channel.readPlaintext(maxLength: 64 * 1024)
            if plaintext.isEmpty {
                if channel.state == .peerClosed {
                    finish(.clientClosed)
                }
                return
            }
            consumeRequestPlaintext(plaintext)
        }
    }

    private func consumeRequestPlaintext(_ plaintext: Data) {
        guard state == .readingRequest else { return }
        if requestHead == nil {
            requestHeadInputBytes += plaintext.count
            switch parser.feed(plaintext) {
            case .needMore:
                return
            case .invalid, .connect:
                reject(statusCode: 400)
            case .request(let head):
                let parsedHeadBytes =
                    requestHeadInputBytes - parser.leftover.count
                guard parsedHeadBytes <= Self.maximumRequestHeadBytes else {
                    reject(statusCode: 400)
                    return
                }
                guard validate(head: head) else { return }
                requestHead = head
                requestBody = parser.leftover
                guard requestBody.count <= (expectedBodyLength ?? 0) else {
                    reject(statusCode: 400)
                    return
                }
                completeRequestIfReady()
            }
        } else {
            guard let expectedBodyLength else {
                reject(statusCode: 400)
                return
            }
            guard plaintext.count <= expectedBodyLength - requestBody.count else {
                reject(statusCode: 400)
                return
            }
            requestBody.append(plaintext)
            completeRequestIfReady()
        }
    }

    private func validate(head: ProxyHTTPParser.HTTPRequestHead) -> Bool {
        let method = head.method.uppercased()
        guard method != "CONNECT" else {
            reject(statusCode: 400)
            return false
        }
        guard ["GET", "POST", "HEAD"].contains(method) else {
            reject(statusCode: 501)
            return false
        }
        guard head.path.hasPrefix("/"), !head.path.contains("://") else {
            reject(statusCode: 400)
            return false
        }

        let hostHeaders = head.headers.filter {
            $0.0.caseInsensitiveCompare("Host") == .orderedSame
        }
        guard hostHeaders.count == 1,
              let innerAuthority = Self.parseAuthority(hostHeaders[0].1),
              innerAuthority.host == normalizedOuterHost,
              innerAuthority.port == 443
        else {
            reject(statusCode: 400)
            return false
        }

        let transferEncodings = head.headers.filter {
            $0.0.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
        }
        let contentLengths = head.headers.filter {
            $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame
        }
        guard transferEncodings.isEmpty || contentLengths.isEmpty else {
            reject(statusCode: 400)
            return false
        }
        guard transferEncodings.isEmpty else {
            reject(statusCode: 501)
            return false
        }
        guard contentLengths.count <= 1 else {
            reject(statusCode: 400)
            return false
        }

        let length: Int
        if let value = contentLengths.first?.1 {
            guard let parsed = Int(value), parsed >= 0 else {
                reject(statusCode: 400)
                return false
            }
            length = parsed
        } else {
            length = 0
        }
        guard length <= Self.maximumRequestBodyBytes else {
            reject(statusCode: 400)
            return false
        }
        expectedBodyLength = length
        return true
    }

    private func completeRequestIfReady() {
        guard state == .readingRequest,
              let head = requestHead,
              let expectedBodyLength,
              requestBody.count == expectedBodyLength
        else {
            return
        }
        cancelTimer(.request)

        if let localResponse = localResourceHandler?(head, requestBody) {
            guard localResponse.body.count <= Self.maximumResponseBytes else {
                respondWithError(statusCode: 502)
                return
            }
            beginResponse(Self.serialize(localResponse))
            return
        }

        let request = Self.serializeUpstreamRequest(
            head: head,
            body: requestBody,
            fixedHost: outerHost
        )
        state = .waitingForUpstream
        arm(.upstream, after: timeouts.upstream)
        upstreamTask = upstreamExecutor.execute(
            host: outerHost,
            request: request,
            responseLimit: Self.maximumResponseBytes,
            timeout: timeouts.upstream
        ) { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                self.handleUpstreamResult(result)
            }
        }
    }

    private func handleUpstreamResult(_ result: Result<Data, Error>) {
        guard state == .waitingForUpstream else { return }
        cancelTimer(.upstream)
        upstreamTask = nil
        switch result {
        case .success(let response):
            guard response.count <= Self.maximumResponseBytes,
                  let sanitized = Self.sanitizeUpstreamResponse(response)
            else {
                respondWithError(statusCode: 502)
                return
            }
            beginResponse(sanitized)
        case .failure:
            respondWithError(statusCode: 502)
        }
    }

    private func reject(statusCode: Int) {
        guard state == .readingRequest else { return }
        cancelTimer(.request)
        respondWithError(statusCode: statusCode)
    }

    private func respondWithError(statusCode: Int) {
        let body = Data()
        beginResponse(
            Self.serialize(
                ResourceResponse(
                    statusCode: statusCode,
                    headers: [("Content-Type", "text/plain")],
                    body: body
                )
            )
        )
    }

    private func beginResponse(_ response: Data) {
        guard response.count <= Self.maximumResponseBytes + Self.maximumRequestHeadBytes else {
            finish(.transportFailure)
            return
        }
        pendingResponse = response
        pendingResponseOffset = 0
        state = .writingResponse
        drive()
    }

    private func writePendingResponse() {
        for _ in 0..<16 where state == .writingResponse {
            if pendingResponseOffset == pendingResponse.count {
                pendingResponse.removeAll(keepingCapacity: false)
                state = .closing
                driveTLSClose()
                return
            }
            let end = min(pendingResponse.count, pendingResponseOffset + 16 * 1024)
            let chunk = pendingResponse.subdata(in: pendingResponseOffset..<end)
            let written: Int
            do {
                written = try channel.writePlaintext(chunk)
            } catch {
                finish(.tlsFailure)
                return
            }
            guard written > 0 else { return }
            pendingResponseOffset += written
        }
    }

    private func driveTLSClose() {
        guard state == .closing else { return }
        do {
            _ = try channel.close()
            if channel.state == .closed,
               channel.bufferedEncryptedOutputBytes == 0,
               !sendInFlight
            {
                finish(.completed)
            }
        } catch {
            finish(.tlsFailure)
        }
    }

    private func scheduleReceiveIfNeeded() {
        guard !receiveInFlight,
              state == .handshaking || state == .readingRequest
        else {
            return
        }
        receiveInFlight = true
        client.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.stateQueue.async {
                self.receiveInFlight = false
                guard self.state != .closed else { return }
                if error != nil {
                    self.finish(.transportFailure)
                    return
                }
                do {
                    if let data, !data.isEmpty {
                        try self.channel.receiveEncrypted(data)
                    }
                    if isComplete {
                        self.channel.markEncryptedInputEOF()
                    }
                    self.drive()
                    if isComplete, self.state != .closed,
                       self.state != .writingResponse, self.state != .closing
                    {
                        self.finish(.clientClosed)
                    }
                } catch {
                    self.finish(.tlsFailure)
                }
            }
        }
    }

    private func flushEncryptedOutput() {
        guard !sendInFlight, state != .closed else { return }
        let ciphertext = channel.drainEncryptedOutput(maxLength: 64 * 1024)
        guard !ciphertext.isEmpty else {
            if state == .closing {
                if channel.state == .closed {
                    finish(.completed)
                } else {
                    driveTLSClose()
                }
            }
            return
        }
        sendInFlight = true
        client.send(
            content: ciphertext,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.stateQueue.async {
                    self.sendInFlight = false
                    if error != nil {
                        self.finish(.transportFailure)
                    } else {
                        self.drive()
                    }
                }
            }
        )
    }

    private func arm(_ kind: TimerKind, after interval: TimeInterval) {
        let token = UUID()
        timerTokens[kind] = token
        stateQueue.asyncAfter(deadline: .now() + max(0.001, interval)) {
            [weak self] in
            guard let self, self.timerTokens[kind] == token else { return }
            self.timerTokens.removeValue(forKey: kind)
            self.handleTimeout(kind)
        }
    }

    private func cancelTimer(_ kind: TimerKind) {
        timerTokens.removeValue(forKey: kind)
    }

    private func handleTimeout(_ kind: TimerKind) {
        guard state != .closed else { return }
        switch kind {
        case .handshake, .total:
            finish(.timeout)
        case .request:
            respondWithError(statusCode: 400)
        case .upstream:
            upstreamTask?.cancel()
            upstreamTask = nil
            respondWithError(statusCode: 502)
        }
    }

    private func finish(_ reason: CloseReason) {
        guard state != .closed else { return }
        state = .closed
        timerTokens.removeAll()
        upstreamTask?.cancel()
        upstreamTask = nil
        client.stateUpdateHandler = nil
        client.cancel()
        guard !closeCallbackDelivered else { return }
        closeCallbackDelivered = true
        onClosed?(reason)
    }

    private static func normalizeDNSHost(_ host: String) -> String? {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty,
              !normalized.contains("/"),
              !normalized.contains("@"),
              !normalized.contains(":")
        else {
            return nil
        }
        return normalized
    }

    private static func parseAuthority(_ authority: String) -> (
        host: String,
        port: Int
    )? {
        let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("[") else { return nil }
        let components = trimmed.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count == 1 || components.count == 2,
              let host = normalizeDNSHost(String(components[0]))
        else {
            return nil
        }
        let port: Int
        if components.count == 2 {
            guard let parsed = Int(components[1]), (1...65_535).contains(parsed)
            else {
                return nil
            }
            port = parsed
        } else {
            port = 443
        }
        return (host, port)
    }

    private static func serializeUpstreamRequest(
        head: ProxyHTTPParser.HTTPRequestHead,
        body: Data,
        fixedHost: String
    ) -> Data {
        let connectionTokens = headerTokens(
            head.headers,
            named: "Connection"
        )
        let standardHopByHop: Set<String> = [
            "connection", "proxy-connection", "keep-alive",
            "transfer-encoding", "te", "trailer", "upgrade"
        ]
        var text = "\(head.method.uppercased()) \(head.path) HTTP/1.1\r\n"
        text += "Host: \(fixedHost)\r\n"
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "host"
                || lower == "content-length"
                || standardHopByHop.contains(lower)
                || connectionTokens.contains(lower)
            {
                continue
            }
            text += "\(name): \(value)\r\n"
        }
        if head.header("Content-Length") != nil || !body.isEmpty {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        var result = Data(text.utf8)
        result.append(body)
        return result
    }

    private static func serialize(_ response: ResourceResponse) -> Data {
        var text = "HTTP/1.1 \(response.statusCode) "
        text += "\(reasonPhrase(response.statusCode))\r\n"
        for (name, value) in response.headers {
            let lower = name.lowercased()
            guard lower != "connection", lower != "content-length" else {
                continue
            }
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(response.body.count)\r\n"
        text += "Connection: close\r\n\r\n"
        var result = Data(text.utf8)
        result.append(response.body)
        return result
    }

    private static func sanitizeUpstreamResponse(_ response: Data) -> Data? {
        guard let delimiter = response.range(of: Data("\r\n\r\n".utf8)),
              delimiter.lowerBound <= maximumRequestHeadBytes,
              let headText = String(
                  data: response[..<delimiter.lowerBound],
                  encoding: .isoLatin1
              )
        else {
            return nil
        }
        var lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first,
              statusLine.hasPrefix("HTTP/1.")
        else {
            return nil
        }
        lines.removeFirst()
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let connectionTokens = headerTokens(headers, named: "Connection")
        let standardHopByHop: Set<String> = [
            "connection", "proxy-connection", "keep-alive",
            "te", "trailer", "upgrade"
        ]
        var rebuilt = "\(statusLine)\r\n"
        for (name, value) in headers {
            let lower = name.lowercased()
            if standardHopByHop.contains(lower)
                || connectionTokens.contains(lower)
            {
                continue
            }
            rebuilt += "\(name): \(value)\r\n"
        }
        rebuilt += "Connection: close\r\n\r\n"
        var result = Data(rebuilt.utf8)
        result.append(response[delimiter.upperBound...])
        return result
    }

    private static func headerTokens(
        _ headers: [(String, String)],
        named name: String
    ) -> Set<String> {
        Set(
            headers
                .filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }
                .flatMap { $0.1.split(separator: ",") }
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
        )
    }

    private static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        default: return "Response"
        }
    }
}
