import WebKit

final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    var onProcessTerminated: (() -> Void)?
    var onNavigation: ((URL?) -> Void)?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagnosticsStore.shared.recordProcessTermination()
        webView.reload()
        onProcessTerminated?()
    }
    func webView(_ wv: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { onNavigation?(wv.url) }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        DiagnosticsStore.shared.recordNavigationError(e.localizedDescription)
    }
}
