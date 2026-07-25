import WebKit

/// 统一消息桥：页面内 window.webkit.messageHandlers.gotoBrowser.postMessage({type:..., ...})
final class JSBridge: NSObject, WKScriptMessageHandler {
    private static let maxCaptureCharacters = 32 * 1_024 * 1_024
    private static let maxAPIResponseCharacters = 16 * 1_024 * 1_024
    private static let maxAPIRequestCharacters = 1 * 1_024 * 1_024
    private static let maxEndpointCharacters = 4_096
    private static let maxLogCharacters = 16_384

    enum Event {
        case capture(dataURL: String)
        case kcsapi(endpoint: String, request: String?, response: String)
        case apiError(code: Int)
        case memoryReport(jsHeapMB: Double)
        case log(String)
    }
    var onEvent: (Event) -> Void = { _ in }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let type = dict["type"] as? String else { return }
        let host = Self.normalizedHost(message.frameInfo.securityOrigin.host)
        switch type {
        case "capture":
            guard Self.isGameMessageHost(host),
                  let data = dict["data"] as? String,
                  data.count <= Self.maxCaptureCharacters,
                  data.hasPrefix("data:image/png;base64,") else { return }
            onEvent(.capture(dataURL: data))
        case "kcsapi":
            guard Self.isGameMessageHost(host),
                  let endpoint = dict["endpoint"] as? String,
                  endpoint.count <= Self.maxEndpointCharacters,
                  endpoint.hasPrefix("/kcsapi/"),
                  let response = dict["response"] as? String,
                  response.count <= Self.maxAPIResponseCharacters else { return }
            let request = dict["request"] as? String
            guard request?.count ?? 0 <= Self.maxAPIRequestCharacters else { return }
            onEvent(.kcsapi(endpoint: endpoint, request: request, response: response))
        case "apiError":
            guard Self.isGameMessageHost(host) else { return }
            onEvent(.apiError(code: dict["code"] as? Int ?? 0))
        case "memory":
            guard Self.isKnownPageHost(host) else { return }
            onEvent(.memoryReport(jsHeapMB: dict["jsHeapMB"] as? Double ?? 0))
        case "log":
            guard Self.isKnownPageHost(host),
                  let text = dict["text"] as? String,
                  text.count <= Self.maxLogCharacters else { return }
            onEvent(.log(text))
        default:
            return
        }
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        let host = rawHost.lowercased()
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private static func matches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func isGameMessageHost(_ host: String) -> Bool {
        matches(host, domain: "kancolle-server.com")
            || matches(host, domain: "ooi.moe")
            || matches(host, domain: "kancolle.moe")
    }

    private static func isKnownPageHost(_ host: String) -> Bool {
        isGameMessageHost(host)
            || matches(host, domain: "dmm.com")
            || matches(host, domain: "games.dmm.com")
    }
}
