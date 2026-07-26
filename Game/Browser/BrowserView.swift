import SwiftUI
import WebKit
import Network
import GameCore

struct BrowserView: UIViewRepresentable {
    let url: URL
    let proxyPort: UInt16
    let settings: SettingsStore
    let bridge: JSBridge
    let controller: BrowserController?
    let onNavigationFinished: ((WKWebView) -> Void)?
    let onGameReady: (() -> Void)?
    let onProcessTerminated: (() -> Void)?

    init(url: URL,
         proxyPort: UInt16,
         settings: SettingsStore,
         bridge: JSBridge,
         controller: BrowserController? = nil,
         onNavigationFinished: ((WKWebView) -> Void)? = nil,
         onGameReady: (() -> Void)? = nil,
         onProcessTerminated: (() -> Void)? = nil) {
        self.url = url
        self.proxyPort = proxyPort
        self.settings = settings
        self.bridge = bridge
        self.controller = controller
        self.onNavigationFinished = onNavigationFinished
        self.onGameReady = onGameReady
        self.onProcessTerminated = onProcessTerminated
    }

    /// Runs in the DMM shell and in the game iframe. The shell is reduced to the
    /// 1200×720 game frame; inside the iframe the game surface fills that viewport.
    /// Keeping the original aspect ratio avoids shifting hit targets on wide iPhones.
    private static let gameLayoutScript = """
    (() => {
      if (window.__gotoGameLayoutInstalled) return;
      window.__gotoGameLayoutInstalled = true;
      const style = document.createElement("style");
      style.textContent = `
        html,body{margin:0!important;padding:0!important;width:100%!important;height:100%!important;overflow:hidden!important;background:#000!important}
        header,footer,nav,.dmm-ntgnavi,.area-naviapp,#ntg-recommend,#foot,#spacing_top,#sectionWrap{display:none!important}
        .gamesResetStyle>main,#main-ntg,#area-game,#page,#w{margin:0!important;padding:0!important;max-width:none!important}
        .gamesResetStyle>:not(main){display:none!important}
        #game_frame,#externalswf{border:0!important;transform-origin:top left!important}
      `;
      (document.head || document.documentElement).appendChild(style);
      const signalGameReady = () => {
        const host = (location.hostname || "").toLowerCase();
        const hasGameFrame =
          document.getElementById("game_frame") ||
          document.getElementById("externalswf") ||
          document.querySelector('iframe[src*="kancolle-server.com"]');
        if (host.endsWith("kancolle-server.com") || hasGameFrame) {
          try {
            window.webkit.messageHandlers.gotoGameLifecycle.postMessage({type:"gameReady"});
          } catch (_) {}
        }
      };
      const resize = () => {
        const frame = document.getElementById("game_frame") || document.getElementById("externalswf");
        if (frame) {
          const scale = Math.min(innerWidth / 1200, innerHeight / 720);
          frame.style.position = "fixed";
          frame.style.width = "1200px";
          frame.style.height = "720px";
          frame.style.left = `${Math.max(0, (innerWidth - 1200 * scale) / 2)}px`;
          frame.style.top = `${Math.max(0, (innerHeight - 720 * scale) / 2)}px`;
          frame.style.transform = `scale(${scale})`;
        }
        signalGameReady();
      };
      new MutationObserver(resize).observe(document.documentElement,{childList:true,subtree:true});
      addEventListener("resize",resize,{passive:true});
      addEventListener("webglcontextlost",event=>{
        event.preventDefault();
        try{window.webkit.messageHandlers.gotoBrowser.postMessage({type:"log",text:"WEBGL_CONTEXT_LOST"});}catch(_){}
      },true);
      addEventListener("webglcontextrestored",()=>{
        try{window.webkit.messageHandlers.gotoBrowser.postMessage({type:"log",text:"WEBGL_CONTEXT_RESTORED"});}catch(_){}
        resize();
      },true);
      resize();
    })();
    """

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(controller: controller ?? BrowserController())
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if proxyPort > 0, let port = NWEndpoint.Port(rawValue: proxyPort) {
            // iOS 17+：全部 WebView 流量走本地代理（HTTP CONNECT）
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
        }
        // viewport 依赖 document.head，故在 documentEnd 注入；正式布局脚本必须
        // 同时进入 DMM 外壳与游戏 iframe，才能隐藏页面杂项并只保留游戏画面。
        // API 桥必须早于游戏脚本进入所有 frame，直接包装 XHR/fetch；因此即使
        // HTTPS 只能以 CONNECT 盲隧道通过本地代理，也仍能在页面进程内采集 kcsapi。
        let apiBridge = WKUserScript(
            source: ScriptPatcher.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        let viewport = WKUserScript(source: BrowserConstants.viewportMetaScript,
                                    injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let gameLayout = WKUserScript(source: Self.gameLayoutScript,
                                      injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(apiBridge)
        config.userContentController.addUserScript(viewport)
        config.userContentController.addUserScript(gameLayout)
        config.userContentController.add(bridge, name: "gotoBrowser")
        config.userContentController.add(context.coordinator, name: "gotoGameLifecycle")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = settings.legacyRenderer ? BrowserConstants.userAgentIOSCanvas : BrowserConstants.userAgentDesktop
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        context.coordinator.attach(webView)
        context.coordinator.onNavigationFinished = onNavigationFinished
        context.coordinator.onGameReady = onGameReady
        context.coordinator.onProcessTerminated = onProcessTerminated
        webView.load(URLRequest(url: url))
        return webView
    }

    // 当前为一次性配置：makeUIView 之后 url / settings / proxyPort 的变更不会生效
    //（SwiftUI 更新不重建 WKWebView，也不重新 load）。任务 12 正式接线时按需处理。
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onNavigationFinished = onNavigationFinished
        context.coordinator.onGameReady = onGameReady
        context.coordinator.onProcessTerminated = onProcessTerminated
    }
}
