import SwiftUI
import WebKit
import Network
import GameCore

struct BrowserView: UIViewRepresentable {
    let url: URL
    let proxyPort: UInt16
    let settings: SettingsStore
    let bridge: JSBridge

    // TODO(任务6后清理)：Spike 探针脚本（kcsapi XHR 钩子 + main.js 改写标记检测）
    private static let spikeProbeScript = """
    (function(){var O=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){try{if(u&&u.indexOf("/kcsapi/")>=0){window.webkit.messageHandlers.gotoBrowser.postMessage({type:"kcsapi",endpoint:String(u).split("?")[0],request:null,response:""});}}catch(e){}return O.apply(this,arguments);};})();
    window.addEventListener("load",function(){try{if(window.__SPIKE_PATCHED){window.webkit.messageHandlers.gotoBrowser.postMessage({type:"log",text:"SPIKE_PATCHED_OK"});}}catch(e){}});
    """

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
        // 拆成两个独立脚本，避免任一脚本异常影响另一个：
        // - viewport 需要 document.head，atDocumentStart 时几乎必然为 undefined，
        //   故 atDocumentEnd 注入（Android 原版是页面加载后 evaluateJavascript，见 BrowserConstants）
        // - 内存探针是 setInterval + messageHandlers，atDocumentStart 安全
        // 均 forMainFrameOnly: true，避免 iframe 重复注入/重复上报内存
        let viewport = WKUserScript(source: BrowserConstants.viewportMetaScript,
                                    injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let memoryProbe = WKUserScript(source: BrowserConstants.memoryProbeScript,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(viewport)
        config.userContentController.addUserScript(memoryProbe)
        // TODO(任务6后清理)：Spike 探针脚本（合并为一条 WKUserScript）：
        // 1) kcsapi XHR 钩子——只验证钩子能装进游戏 iframe 并触发桥，不解析响应；
        // 2) main.js 改写验证——代理在 main.js 末尾追加 window.__SPIKE_PATCHED=1，
        //    页面 load 后若读到该标记则上报 SPIKE_PATCHED_OK（证明改写+注入全链路通）。
        // forMainFrameOnly: false——游戏跑在 iframe 里，必须进 iframe 才能钩到。
        let spikeProbe = WKUserScript(source: Self.spikeProbeScript,
                                      injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(spikeProbe)
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

    // 当前为一次性配置：makeUIView 之后 url / settings / proxyPort 的变更不会生效
    //（SwiftUI 更新不重建 WKWebView，也不重新 load）。任务 12 正式接线时按需处理。
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
