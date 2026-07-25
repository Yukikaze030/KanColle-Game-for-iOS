import WebKit

/// 统一消息桥：页面内 window.webkit.messageHandlers.gotoBrowser.postMessage({type:..., ...})
final class JSBridge: NSObject, WKScriptMessageHandler {
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
        switch type {
        case "capture":
            if let data = dict["data"] as? String { onEvent(.capture(dataURL: data)) }
        case "kcsapi":
            onEvent(.kcsapi(endpoint: dict["endpoint"] as? String ?? "",
                            request: dict["request"] as? String,
                            response: dict["response"] as? String ?? ""))
        case "apiError":
            onEvent(.apiError(code: dict["code"] as? Int ?? 0))
        case "memory":
            onEvent(.memoryReport(jsHeapMB: dict["jsHeapMB"] as? Double ?? 0))
        default:
            onEvent(.log(String(describing: message.body)))
        }
    }
}
