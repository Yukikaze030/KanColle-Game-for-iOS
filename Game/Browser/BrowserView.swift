import SwiftUI
import WebKit
import Network
import GameCore

struct BrowserView: UIViewRepresentable {
    let url: URL
    let proxyPort: UInt16
    var settings: SettingsStore
    let bridge: JSBridge

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if proxyPort > 0, let port = NWEndpoint.Port(rawValue: proxyPort) {
            // iOS 17+：全部 WebView 流量走本地代理（HTTP CONNECT）
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
        }
        let probe = WKUserScript(source: BrowserConstants.viewportMetaScript + BrowserConstants.memoryProbeScript,
                                 injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(probe)
        config.userContentController.add(bridge, name: "gotoBrowser")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = settings.legacyRenderer ? BrowserConstants.userAgentIOSCanvas : BrowserConstants.userAgentDesktop
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.bounces = false
        wv.isOpaque = true
        context.coordinator.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}
