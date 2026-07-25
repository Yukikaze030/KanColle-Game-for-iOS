import Foundation
import Network

/// 一条经过代理的请求日志（任务 8 复用）。
public struct ProxyRequestLog: Sendable {
    public let host: String
    public let path: String
    public let statusCode: Int?
    public let blocked: Bool

    public init(host: String, path: String, statusCode: Int?, blocked: Bool) {
        self.host = host
        self.path = path
        self.statusCode = statusCode
        self.blocked = blocked
    }
}

/// 本地短路响应（任务 8 缓存层通过 onGameResourceRequest 返回它）。
public struct ResourceResponse: Sendable {
    public var statusCode: Int
    public var headers: [(String, String)]
    public var body: Data
    public init(statusCode: Int, headers: [(String, String)], body: Data) {
        self.statusCode = statusCode; self.headers = headers; self.body = body
    }
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reasonPhrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "Response"
        }
    }
}

/// 本地 HTTP 代理：CONNECT 隧道（443）/ HTTP 终止（80）/ 普通请求转发 + 阻断。
/// P1 简化：对上游一律 Connection: close（每请求一连接），不做 keep-alive；
/// ProxyHTTPParser 单次使用（解析出头部即丢弃）。
public final class LocalProxyServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public var onRequest: ((ProxyRequestLog) -> Void)?
    public var onGameResourceRequest: ((ProxyHTTPParser.HTTPRequestHead) -> ResourceResponse?)?
    public var isInspectableHost: ((String, Int) -> Bool) = { host, port in
        (port == 80 || port == 443)
            && LocalProxyServer.isGameServerHost(host)
    }
    public var mitmCA: MitmCA?
    public var isMitmHost: ((String) -> Bool) = { host in
        LocalProxyServer.isGameServerHost(host)
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "localproxy", attributes: .concurrent)
    private let registryLock = NSLock()
    private var active: [ObjectIdentifier: NWConnection] = [:]
    private var activeMitmSessions: [UUID: MitmSession] = [:]
    var tunnelConnectionFactory: (String, Int) -> NWConnection = { host, port in
        NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port))!,
            using: .tcp
        )
    }

    var activeMitmSessionCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        return activeMitmSessions.count
    }
    var onMitmSessionStarted: ((Int) -> Void)?
    var onMitmSessionClosed: ((MitmSession.CloseReason) -> Void)?

    public init() {}

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = l.port?.rawValue ?? 0 }
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        registryLock.lock()
        let conns = Array(active.values)
        let sessions = Array(activeMitmSessions.values)
        active.removeAll()
        registryLock.unlock()
        // Sessions remain strongly held until their idempotent onClosed
        // callback removes them from the registry.
        sessions.forEach { $0.cancel() }
        conns.forEach { $0.cancel() }
    }

    // MARK: - Connection registry（stop() 时统一 cancel，避免泄漏）

    private func track(_ conn: NWConnection) {
        registryLock.lock()
        active[ObjectIdentifier(conn)] = conn
        registryLock.unlock()
    }

    private func untrack(_ conn: NWConnection) {
        registryLock.lock()
        active.removeValue(forKey: ObjectIdentifier(conn))
        registryLock.unlock()
    }

    // MARK: - 入口：解析首个请求头并分流

    private func handle(_ conn: NWConnection) {
        track(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                self.untrack(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
        readHead(conn) { [weak self] head, leftover in
            guard let self else { conn.cancel(); return }
            switch head {
            case .connect(let host, let port):
                self.handleConnect(
                    conn,
                    host: host,
                    port: port,
                    initialTunnelData: leftover
                )
            case .request(let req):
                self.serveHTTPRequest(conn, head: req, leftover: leftover)
            case .needMore, .invalid:
                conn.cancel()
            }
        }
    }

    /// 累积 receive 直到解析出完整头部（parser 单次使用，产出结果后丢弃）。
    /// 返回解析结果与紧随头部的多余字节（请求 body 的开头）。
    private func readHead(_ conn: NWConnection,
                          completion: @escaping (ProxyHTTPParser.ParseResult, Data) -> Void) {
        var parser = ProxyHTTPParser()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { conn.cancel(); return }
                if let data, !data.isEmpty, error == nil {
                    let result = parser.feed(data)
                    switch result {
                    case .needMore:
                        receive()
                    case .request, .connect, .invalid:
                        completion(result, parser.leftover)
                    }
                } else if error == nil && !isComplete {
                    // 空包但未结束：继续等
                    receive()
                } else {
                    // 对端关闭或出错
                    self.untrack(conn)
                    conn.cancel()
                }
            }
        }
        receive()
    }

    // MARK: - CONNECT 分流

    private func handleConnect(
        _ conn: NWConnection,
        host: String,
        port: Int,
        initialTunnelData: Data
    ) {
        if BlockRules.isBlocked(host: host) {
            log(ProxyRequestLog(host: host, path: "CONNECT:\(port)", statusCode: 403, blocked: true))
            reply(conn, Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) {
                conn.cancel()
            }
            return
        }
        log(ProxyRequestLog(host: host, path: "CONNECT:\(port)", statusCode: 200, blocked: false))
        if port == 443,
           let mitmCA,
           isMitmHost(host),
           startMitmSession(
               conn,
               host: host,
               initialEncryptedData: initialTunnelData,
               certificateAuthority: mitmCA
           )
        {
            return
        } else if port == 80 {
            // HTTP 终止模式：回 200 后按普通 HTTP 请求处理后续流量
            reply(conn, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) { [weak self] in
                guard let self else { conn.cancel(); return }
                self.readHead(conn) { [weak self] result, leftover in
                    guard let self else { conn.cancel(); return }
                    switch result {
                    case .request(let head):
                        self.serveHTTPRequest(conn, head: head, leftover: leftover)
                    default:
                        conn.cancel()
                    }
                }
            }
        } else {
            tunnel(
                conn,
                host: host,
                port: port,
                initialTunnelData: initialTunnelData
            )
        }
    }

    private func startMitmSession(
        _ conn: NWConnection,
        host: String,
        initialEncryptedData: Data,
        certificateAuthority: MitmCA
    ) -> Bool {
        let session: MitmSession
        do {
            session = try MitmSession(
                clientConnection: conn,
                host: host,
                certificateAuthority: certificateAuthority,
                localResourceHandler: { [weak self] head, _ in
                    guard let self else { return nil }
                    let urlString = "https://\(head.host)\(head.path)"
                    if BlockRules.isBlocked(urlString: urlString) {
                        self.log(
                            ProxyRequestLog(
                                host: head.host,
                                path: head.path,
                                statusCode: 200,
                                blocked: true
                            )
                        )
                        return ResourceResponse(
                            statusCode: 200,
                            headers: [("Content-Type", "text/plain")],
                            body: Data()
                        )
                    }
                    guard self.isInspectableHost(head.host, 443) else {
                        return nil
                    }
                    let local = self.onGameResourceRequest?(head)
                    if let local {
                        self.log(
                            ProxyRequestLog(
                                host: head.host,
                                path: head.path,
                                statusCode: local.statusCode,
                                blocked: false
                            )
                        )
                    }
                    return local
                }
            )
        } catch {
            return false
        }

        let sessionID = UUID()
        session.onClosed = { [weak self, weak conn] reason in
            guard let self else { return }
            self.registryLock.lock()
            self.activeMitmSessions.removeValue(forKey: sessionID)
            self.registryLock.unlock()
            if let conn {
                self.untrack(conn)
            }
            self.onMitmSessionClosed?(reason)
        }
        registryLock.lock()
        activeMitmSessions[sessionID] = session
        registryLock.unlock()

        conn.send(
            content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
            completion: .contentProcessed { [weak self] error in
                if error == nil {
                    self?.onMitmSessionStarted?(initialEncryptedData.count)
                    session.start(initialEncryptedData: initialEncryptedData)
                } else {
                    session.cancel()
                    conn.cancel()
                }
            }
        )
        return true
    }

    /// 443 隧道：回 200 后双向透传。
    private func tunnel(
        _ conn: NWConnection,
        host: String,
        port: Int,
        initialTunnelData: Data = Data()
    ) {
        guard (1...65_535).contains(port) else {
            conn.cancel()
            return
        }
        let upstream = tunnelConnectionFactory(host, port)
        track(upstream)
        upstream.stateUpdateHandler = { [weak self, weak conn, weak upstream] state in
            guard let self, let conn, let upstream else { return }
            switch state {
            case .ready:
                self.reply(conn, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) {
                    let beginPumps = {
                        self.pump(conn, to: upstream)
                        self.pump(upstream, to: conn)
                    }
                    if initialTunnelData.isEmpty {
                        beginPumps()
                    } else {
                        upstream.send(
                            content: initialTunnelData,
                            completion: .contentProcessed { error in
                                if error == nil {
                                    beginPumps()
                                } else {
                                    self.closePair(conn, upstream)
                                }
                            }
                        )
                    }
                }
            case .failed, .cancelled:
                self.untrack(upstream)
                conn.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func pump(_ from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak from, weak to] data, _, isComplete, error in
            guard let self, let from, let to else { return }
            if let data, !data.isEmpty, error == nil {
                to.send(content: data, completion: .contentProcessed { [weak self, weak from, weak to] sendError in
                    guard let self, let from, let to else { return }
                    if sendError != nil {
                        self.closePair(from, to)
                    } else {
                        self.pump(from, to: to)
                    }
                })
            } else {
                // 任一侧结束/出错：双向 cancel
                self.closePair(from, to)
            }
        }
    }

    private func closePair(_ a: NWConnection, _ b: NWConnection) {
        a.cancel()
        b.cancel()
        untrack(a)
        untrack(b)
    }

    // MARK: - 普通 HTTP 请求

    private func serveHTTPRequest(_ conn: NWConnection, head: ProxyHTTPParser.HTTPRequestHead,
                                  leftover: Data) {
        let urlString = "http://\(head.host)\(head.path)"
        if BlockRules.isBlocked(urlString: urlString) {
            log(ProxyRequestLog(host: head.host, path: head.path, statusCode: 200, blocked: true))
            let empty = ResourceResponse(statusCode: 200,
                                         headers: [("Content-Type", "text/plain")],
                                         body: Data())
            reply(conn, empty.serialized()) { conn.cancel() }
            return
        }
        // 只有可检查 host（默认 kancolle-server.com:80）才走缓存短路回调；
        // 其余 host 直接回源转发
        if isInspectableHost(head.host, head.port), let local = onGameResourceRequest?(head) {
            log(ProxyRequestLog(host: head.host, path: head.path, statusCode: local.statusCode, blocked: false))
            reply(conn, local.serialized()) { conn.cancel() }
            return
        }
        forward(conn, head: head, leftover: leftover)
    }

    /// 回源转发：先按 Content-Length 从客户端收满 body（leftover 为已到达的开头），
    /// 再重建请求（剔除 Connection/Proxy-Connection，加 Connection: close）发给上游，
    /// 累积完整响应后原样回传给客户端。
    private func forward(_ conn: NWConnection, head: ProxyHTTPParser.HTTPRequestHead,
                         leftover: Data) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: head.port)) else {
            conn.cancel()
            return
        }
        // Content-Length 缺失或非法（含负数）按 0 处理，防 prefix 越界崩溃
        let contentLength = max(0, head.header("content-length").flatMap(Int.init) ?? 0)
        collectBody(conn, already: leftover, total: contentLength) { [weak self] body in
            guard let self, let body else { conn.cancel(); return }
            let upstream = NWConnection(host: NWEndpoint.Host(head.host), port: nwPort, using: .tcp)
            self.track(upstream)
            upstream.stateUpdateHandler = { [weak self, weak conn, weak upstream] state in
                guard let self, let conn, let upstream else { return }
                switch state {
                case .ready:
                    var raw = "\(head.method) \(head.path) HTTP/1.1\r\n"
                    for (k, v) in head.headers {
                        let lk = k.lowercased()
                        if lk == "connection" || lk == "proxy-connection" { continue }
                        raw += "\(k): \(v)\r\n"
                    }
                    raw += "Connection: close\r\n\r\n"
                    var request = Data(raw.utf8)
                    request.append(body)
                    upstream.send(content: request, completion: .contentProcessed { [weak self, weak conn, weak upstream] error in
                        guard let self, let conn, let upstream else { return }
                        if error != nil {
                            self.closePair(conn, upstream)
                        } else {
                            self.relayResponse(conn, upstream: upstream, head: head, buffer: Data())
                        }
                    })
                case .failed, .cancelled:
                    self.untrack(upstream)
                    conn.cancel()
                default:
                    break
                }
            }
            upstream.start(queue: self.queue)
        }
    }

    /// 从客户端继续 receive 直到收满 total 字节的 body（already 为已到达部分）。
    /// 对端提前关闭或出错时回调 nil。
    private func collectBody(_ conn: NWConnection, already: Data, total: Int,
                             completion: @escaping (Data?) -> Void) {
        if already.count >= total {
            // leftover 可能超出 body（如下一个管线请求的开头），P1 每请求一连接，超出部分丢弃
            completion(Data(already.prefix(total)))
            return
        }
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: max(64 * 1024, total - already.count)) { data, _, isComplete, error in
            var acc = already
            if let data { acc.append(data) }
            if error != nil || (isComplete && acc.count < total) {
                completion(nil)
                return
            }
            self.collectBody(conn, already: acc, total: total, completion: completion)
        }
    }

    /// P1 简化假设：响应全量缓冲进内存（单个游戏资源最大十几 MB 级），
    /// 以 Connection: close 的上游 EOF 作为响应结束信号，再一次回传给客户端。
    /// 后续任务若遇内存压力可改为流式转发（边收边发 + 按头解析结束条件）。
    private func relayResponse(_ conn: NWConnection, upstream: NWConnection,
                               head: ProxyHTTPParser.HTTPRequestHead, buffer: Data) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak conn, weak upstream] data, _, isComplete, error in
            guard let self, let conn, let upstream else { return }
            var acc = buffer
            if let data { acc.append(data) }
            if isComplete || error != nil {
                self.log(ProxyRequestLog(host: head.host, path: head.path,
                                         statusCode: Self.statusCode(of: acc), blocked: false))
                if acc.isEmpty {
                    self.closePair(conn, upstream)
                } else {
                    conn.send(content: acc, completion: .contentProcessed { [weak self, weak conn, weak upstream] _ in
                        guard let self, let conn, let upstream else { return }
                        self.closePair(conn, upstream)
                    })
                }
            } else {
                self.relayResponse(conn, upstream: upstream, head: head, buffer: acc)
            }
        }
    }

    private static func statusCode(of response: Data) -> Int? {
        guard let lineEnd = response.range(of: Data("\r\n".utf8)),
              let line = String(data: response.subdata(in: 0..<lineEnd.lowerBound), encoding: .utf8) else {
            return nil
        }
        let parts = line.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) : nil
    }

    // MARK: - 工具

    private func reply(_ conn: NWConnection, _ data: Data, then: @escaping () -> Void) {
        conn.send(content: data, completion: .contentProcessed { _ in then() })
    }

    private func log(_ entry: ProxyRequestLog) {
        onRequest?(entry)
    }

    private static func isGameServerHost(_ host: String) -> Bool {
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        guard !normalized.hasPrefix("."), !normalized.contains("..") else {
            return false
        }
        return normalized == "kancolle-server.com"
            || normalized.hasSuffix(".kancolle-server.com")
    }
}
