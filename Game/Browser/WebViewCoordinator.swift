import WebKit

final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    /// 供任务 8+（资源缓存/请求拦截/截图等）回连 WebView 使用。
    weak var webView: WKWebView?
    /// 任务 8+ 接线：进程终止后的上层回调（如提示/计数/降级 UA）。
    var onProcessTerminated: (() -> Void)?
    /// 任务 8+ 接线：导航开始回调（URL 变化追踪、latestURL 持久化）。
    var onNavigation: ((URL?) -> Void)?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagnosticsStore.shared.recordProcessTermination()
        // TODO(任务14+)：reload 目前无退避/次数上限，若页面本身导致反复
        // OOM 崩溃会陷入 reload 死循环；后续需加退避与重试上限。
        webView.reload()
        onProcessTerminated?()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onNavigation?(webView.url)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DiagnosticsStore.shared.recordNavigationError(error.localizedDescription)
    }
}
