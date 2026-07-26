import Combine
import Foundation
import WebKit
import GameCore

enum WebContentRecoveryEvent: Equatable {
    case reloadRequired(terminationCount: Int, switchedFromCanvasToWebGL: Bool)
}

@MainActor
final class BrowserController: ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var processTerminationCount = 0

    private(set) weak var webView: WKWebView?
    fileprivate var onSwitchToWebGL: (() -> Void)?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        currentURL = webView.url
    }

    func reload() {
        webView?.reload()
    }

    func purgeVolatileCaches(completion: (() -> Void)? = nil) {
        URLCache.shared.removeAllCachedResponses()
        guard let webView else {
            completion?()
            return
        }
        webView.configuration.websiteDataStore.removeData(
            ofTypes: Set([WKWebsiteDataTypeMemoryCache]),
            modifiedSince: .distantPast
        ) {
            DispatchQueue.main.async { completion?() }
        }
    }

    func switchToWebGLAndReload() {
        guard let webView else { return }
        onSwitchToWebGL?()
        webView.customUserAgent = BrowserConstants.userAgentDesktop
        purgeVolatileCaches { [weak webView] in
            webView?.reload()
        }
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
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let controller: BrowserController
    var onRecovery: ((WebContentRecoveryEvent) -> Void)?
    var onNavigationError: ((String) -> Void)?
    /// 任务 8+ 接线：导航开始回调（URL 变化追踪、latestURL 持久化）。
    var onNavigation: ((URL?) -> Void)?
    var onNavigationFinished: ((WKWebView) -> Void)?
    var onGameReady: (() -> Void)?

    private var didReportGameReady = false
    private var isPollingGameReady = false
    private var recentProcessTerminations: [Date] = []
    private var usesCanvasRenderer = false

    init(controller: BrowserController) {
        self.controller = controller
    }

    func attach(_ webView: WKWebView) {
        controller.attach(webView)
        controller.onSwitchToWebGL = { [weak self] in
            self?.usesCanvasRenderer = false
        }
    }

    func configureRendererRecovery(usesCanvasRenderer: Bool) {
        self.usesCanvasRenderer = usesCanvasRenderer
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagnosticsStore.shared.recordProcessTermination()
        controller.processTerminated()
        let now = Date()
        recentProcessTerminations.removeAll {
            now.timeIntervalSince($0) > 5 * 60
        }
        recentProcessTerminations.append(now)
        let terminationCount = recentProcessTerminations.count

        // Canvas keeps large decoded surfaces in the WebContent process for this
        // game. After its first unexplained termination, prefer GPU-backed WebGL
        // for the rest of this session rather than repeatedly recreating Canvas.
        let switchedRenderer = usesCanvasRenderer
        if switchedRenderer {
            usesCanvasRenderer = false
            webView.customUserAgent = BrowserConstants.userAgentDesktop
        }

        if switchedRenderer {
            DiagnosticsStore.shared.recordCanvasToWebGLFallback()
        }
        // The page's JavaScript/Canvas runtime has already disappeared with the
        // WebContent process. Reloading here would silently navigate away from
        // an in-progress sortie, so only clear disposable caches and let the
        // player explicitly choose whether to rebuild the page.
        controller.purgeVolatileCaches()
        onRecovery?(
            .reloadRequired(
                terminationCount: terminationCount,
                switchedFromCanvasToWebGL: switchedRenderer
            )
        )
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
        reportNavigationError(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        controller.navigationFinished(webView.url)
        reportNavigationError(error)
    }

    private func reportNavigationError(_ error: Error) {
        let nsError = error as NSError
        // WebKit reports redirects, explicit reloads and superseded loads as
        // cancellation. Those are normal control flow and must not present an
        // SSL/network failure alert.
        guard !(nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled) else { return }
        let message = "\(nsError.domain) (\(nsError.code))：\(nsError.localizedDescription)"
        DiagnosticsStore.shared.recordNavigationError(message)
        onNavigationError?(message)
    }

    private func detectGameReady(in webView: WKWebView) {
        guard !didReportGameReady else { return }
        guard !isPollingGameReady else { return }
        isPollingGameReady = true
        pollForGameReady(in: webView, remainingAttempts: 120)
    }

    private func pollForGameReady(in webView: WKWebView, remainingAttempts: Int) {
        guard !didReportGameReady else {
            isPollingGameReady = false
            return
        }
        let script = """
        (() => !!(
          document.getElementById("game_frame") ||
          document.getElementById("externalswf") ||
          document.querySelector('iframe[src*="kancolle-server.com"]') ||
          (location.hostname || "").endsWith("kancolle-server.com")
        ))()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { return }
            if (value as? Bool) == true {
                self.reportGameReady()
            } else if remainingAttempts > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.pollForGameReady(
                        in: webView,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
            } else {
                self.isPollingGameReady = false
            }
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "gotoGameLifecycle",
              let body = message.body as? [String: Any],
              body["type"] as? String == "gameReady" else { return }
        reportGameReady()
    }

    private func reportGameReady() {
        guard !didReportGameReady else { return }
        didReportGameReady = true
        isPollingGameReady = false
        onGameReady?()
    }
}
