import Foundation

/// A Sendable JSON tree used by the game data pipeline. Unknown fields remain harmless
/// without forcing every KanColle response into a rigid Codable schema.
public enum JSONValue: Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .integer(value): return String(value)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .integer(value): return Int(exactly: value)
        case let .number(value) where value.isFinite && value.rounded() == value:
            return Int(exactly: value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case let .integer(value): return value
        case let .number(value) where value.isFinite && value.rounded() == value:
            return Int64(exactly: value)
        case let .string(value): return Int64(value)
        default: return nil
        }
    }
}

public struct APIEnvelope: Sendable, Equatable {
    public let endpoint: String
    public let apiResult: Int?
    public let apiResultMessage: String?
    public let data: JSONValue?
    /// Form parameters are retained only for state updates. `api_token` is always removed.
    public let requestParameters: [String: String]

    public init(
        endpoint: String,
        apiResult: Int?,
        apiResultMessage: String?,
        data: JSONValue?,
        requestParameters: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.apiResult = apiResult
        self.apiResultMessage = apiResultMessage
        self.data = data
        self.requestParameters = requestParameters
    }
}

public struct APIEnvelopeParser: Sendable {
    public enum ParseError: Error, Equatable, LocalizedError {
        case emptyResponse
        case invalidJSON
        case rootIsNotObject

        public var errorDescription: String? {
            switch self {
            case .emptyResponse: return "The API response is empty."
            case .invalidJSON: return "The API response is not valid JSON."
            case .rootIsNotObject: return "The API response root is not an object."
            }
        }
    }

    public init() {}

    public func parse(
        endpoint rawEndpoint: String,
        response: Data,
        requestBody: Data? = nil
    ) throws -> APIEnvelope {
        var payload = response
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) {
            payload.removeFirst(3)
        }
        payload = trimASCIIWhitespace(payload)
        if payload.starts(with: Data("svdata=".utf8)) {
            payload.removeFirst("svdata=".utf8.count)
            payload = trimASCIIWhitespace(payload)
        }
        guard !payload.isEmpty else { throw ParseError.emptyResponse }

        let foundationObject: Any
        do {
            foundationObject = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        } catch {
            throw ParseError.invalidJSON
        }
        guard let root = foundationObject as? [String: Any] else {
            throw ParseError.rootIsNotObject
        }

        let jsonRoot = convert(root)
        guard case let .object(object) = jsonRoot else { throw ParseError.rootIsNotObject }
        return APIEnvelope(
            endpoint: Self.normalizeEndpoint(rawEndpoint),
            apiResult: object["api_result"]?.intValue,
            apiResultMessage: object["api_result_msg"]?.stringValue,
            data: object["api_data"],
            requestParameters: Self.parseRequestParameters(requestBody)
        )
    }

    public static func normalizeEndpoint(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            path = components.percentEncodedPath
        } else {
            path = trimmed.split(separator: "?", maxSplits: 1).first.map(String.init) ?? trimmed
        }

        var decoded = path.removingPercentEncoding ?? path
        decoded = decoded.replacingOccurrences(of: "\\", with: "/")
        if let range = decoded.range(of: "/kcsapi/") {
            decoded = String(decoded[range.upperBound...])
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return "/" }
        return "/" + components.joined(separator: "/")
    }

    private static func parseRequestParameters(_ body: Data?) -> [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = formDecode(String(fields[0]))
            guard key.caseInsensitiveCompare("api_token") != .orderedSame else { continue }
            let value = fields.count > 1 ? formDecode(String(fields[1])) : ""
            result[key] = value
        }
        return result
    }

    private static func formDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }

    private func trimASCIIWhitespace(_ data: Data) -> Data {
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        guard let first = data.firstIndex(where: { !whitespace.contains($0) }) else { return Data() }
        guard let last = data.lastIndex(where: { !whitespace.contains($0) }) else { return Data() }
        return data[first...last]
    }

    private func convert(_ value: Any) -> JSONValue {
        switch value {
        case let object as [String: Any]:
            return .object(object.mapValues(convert))
        case let array as [Any]:
            return .array(array.map(convert))
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            let integer = number.int64Value
            if double.isFinite, Double(integer) == double {
                return .integer(integer)
            }
            return .number(double)
        case is NSNull:
            return .null
        default:
            return .null
        }
    }
}
