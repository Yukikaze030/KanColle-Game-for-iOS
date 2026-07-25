import Foundation

public struct ProxyHTTPParser {
    public enum ParseResult: Equatable {
        case needMore
        case request(HTTPRequestHead)
        case connect(host: String, port: Int)
        case invalid
    }
    public struct HTTPRequestHead: Equatable {
        public let method: String
        public let path: String           // 原始 path（含 query）
        public let host: String           // Host 头（去端口）
        public let port: Int
        public let headers: [(String, String)]
        public static func == (lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
            lhs.method == rhs.method && lhs.path == rhs.path && lhs.host == rhs.host &&
            lhs.port == rhs.port &&
            lhs.headers.count == rhs.headers.count &&
            zip(lhs.headers, rhs.headers).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
        public func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    private var buffer = Data()
    public init() {}

    public mutating func feed(_ data: Data) -> ParseResult {
        buffer.append(data)
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid : .needMore
        }
        let headData = buffer.subdata(in: 0..<range.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [(String, String)] = []
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<i]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)))
        }
        if method.uppercased() == "CONNECT" {
            let hp = target.split(separator: ":")
            guard let h = hp.first else { return .invalid }
            return .connect(host: String(h), port: hp.count > 1 ? Int(hp[1]) ?? 443 : 443)
        }
        // 普通请求：target 可能是绝对 URI（代理形式）或 path
        var host = headers.first { $0.0.lowercased() == "host" }?.1 ?? ""
        var port = 80
        if let i = host.firstIndex(of: ":") { port = Int(host[host.index(after: i)...]) ?? 80; host = String(host[..<i]) }
        var path = target
        if target.lowercased().hasPrefix("http://"), let u = URL(string: target) {
            host = u.host ?? host
            port = u.port ?? 80
            path = u.path + (u.query.map { "?" + $0 } ?? "")
        }
        guard !host.isEmpty else { return .invalid }
        return .request(HTTPRequestHead(method: method, path: path, host: host, port: port, headers: headers))
    }
}
