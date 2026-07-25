import Combine
import Foundation
import WebKit

@MainActor
final class BrowserController: ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var processTerminationCount = 0

    private(set) weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        currentURL = webView.url
    }

    func reload() {
        webView?.reload()
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func evaluateJavaScript(_ source: String,
                            completion: ((Result<Any?, Error>) -> Void)? = nil) {
        guard let webView else {
            completion?(.failure(BrowserControllerError.webViewUnavailable))
            return
        }
        webView.evaluateJavaScript(source) { value, error in
            if let error {
                completion?(.failure(error))
            } else {
                completion?(.success(value))
            }
        }
    }

    fileprivate func navigationStarted(_ url: URL?) {
        currentURL = url
        isLoading = true
    }

    fileprivate func navigationFinished(_ url: URL?) {
        currentURL = url
        isLoading = false
    }

    fileprivate func processTerminated() {
        processTerminationCount += 1
        isLoading = false
    }
}

enum BrowserControllerError: LocalizedError {
    case webViewUnavailable

    var errorDescription: String? {
        "游戏浏览器尚未就绪。"
    }
}

@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    let controller: BrowserController
    /// 任务 8+ 接线：进程终止后的上层回调（如提示/计数/降级 UA）。
    var onProcessTerminated: (() -> Void)?
    /// 任务 8+ 接线：导航开始回调（URL 变化追踪、latestURL 持久化）。
    var onNavigation: ((URL?) -> Void)?
    var onNavigationFinished: ((WKWebView) -> Void)?
    var onGameReady: (() -> Void)?

    private var didReportGameReady = false
    private var recentProcessTerminations: [Date] = []

    init(controller: BrowserController) {
        self.controller = controller
    }

    func attach(_ webView: WKWebView) {
        controller.attach(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagnosticsStore.shared.recordProcessTermination()
        controller.processTerminated()
        let now = Date()
        recentProcessTerminations.removeAll {
            now.timeIntervalSince($0) > 5 * 60
        }
        recentProcessTerminations.append(now)
        // Avoid an OOM reload loop. The first three terminations in five
        // minutes recover automatically; later ones wait for manual reload.
        if recentProcessTerminations.count <= 3 {
            let delay = min(
                Double(recentProcessTerminations.count - 1),
                2
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                webView.reload()
            }
        }
        onProcessTerminated?()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        controller.navigationStarted(webView.url)
        onNavigation?(webView.url)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        controller.navigationFinished(webView.url)
        onNavigationFinished?(webView)
        detectGameReady(in: webView)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        controller.navigationFinished(webView.url)
        DiagnosticsStore.shared.recordNavigationError(error.localizedDescription)
    }

    private func detectGameReady(in webView: WKWebView) {
        guard !didReportGameReady else { return }
        let script = """
        (() => !!(
          document.getElementById("game_frame") ||
          document.getElementById("externalswf") ||
          document.querySelector('iframe[src*="kancolle-server.com"]') ||
          (location.hostname || "").endsWith("kancolle-server.com")
        ))()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, !self.didReportGameReady, (value as? Bool) == true else { return }
            self.didReportGameReady = true
            self.onGameReady?()
        }
    }
}
