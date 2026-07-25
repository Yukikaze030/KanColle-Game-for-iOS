import Foundation

/// Constants ported from GotoBrowser's Constants.java (Android).
/// JS snippets are verbatim copies; the only change is that Android
/// `GotoBrowser.xxx` JavascriptInterface calls are replaced with
/// `window.webkit.messageHandlers.gotoBrowser.postMessage({...})`.
public enum BrowserConstants {
    /// CACHE_DIR in Constants.java is "/browser_cache/"; on iOS we append
    /// this name under the app's caches directory.
    public static let cacheDirName = "browser_cache"

    // MARK: - Connectors (CONN_DMM / CONN_KANMOE / CONN_OOI + URL_*)
    public enum Connector: String, CaseIterable, Sendable {
        case dmm = "DMM direct"
        case kanmoe = "kancolle.moe"
        case ooi = "ooi.moe"

        public var url: URL {
            switch self {
            case .dmm: return URL(string: "https://play.games.dmm.com/game/kancolle")!
            case .kanmoe: return URL(string: "https://kancolle.moe/")!
            case .ooi: return URL(string: "https://ooi.moe/")!
            }
        }

        public var logoutURL: URL {
            switch self {
            case .dmm: return URL(string: "https://www.dmm.com/my/-/login/logout/=/path=Sg9VTQFXDFcXFl5bWlcKGExKUVdUXgFNEU0KSVMVR28MBQ0BUwJZBwxK")!
            case .kanmoe: return URL(string: "https://kancolle.moe/logout")!
            case .ooi: return URL(string: "https://ooi.moe/logout")!
            }
        }
    }

    // MARK: - User agents (iOS-specific, matching GotoBrowser's desktop/mobile UAs)
    public static let userAgentDesktop = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
    public static let userAgentIOSCanvas = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    public static let userAgentMobile = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36"

    // MARK: - URL markers
    public static let urlGoogleAccounts = "https://accounts.google.com/"
    public static let dmmLoginMarkers = ["www.dmm.com/my/-/login/", "accounts.dmm.com/service/login/password"]
    public static let dmmForeignMarkers = ["www.dmm.com/netgame/foreign", "special.dmm.com/not-available-in-your-region"]
    public static let ooiGamePathMarker = "ooi.moe/kancolle"
    public static let kanmoeGamePathMarker = "kancolle.moe/kancolle"

    // MARK: - Gadget server
    public static let gadgetOsapiIfr = "osapi.dmm.com/gadgets/ifr?aid=854854"
    public static let initGameFrame = "artemis.games.dmm.com/member/pc/init-game-frame/kancolle"
    public static let gadgetHTTPHost = "w00g.kancolle-server.com"
    public static let gadgetHTTPURL = "http://w00g.kancolle-server.com/"
    public static let gadgetHTTPSURL = "https://w00g.kancolle-server.com/"
    public static let defaultAlterGadgetURL = "https://kcwiki.github.io/cache/"

    // MARK: - Subtitle data
    public static let githubAPIRoot = "https://api.github.com/"
    public static let subtitleRoot = "https://raw.githubusercontent.com/"
    public static let subtitleSizePath = "src/data/quotes_size.json"
    public static let subtitlePathFormat = "data/%@/quotes.json"
    public static let defaultSubtitleFontSize = 18

    // MARK: - REQUEST_BLOCK_RULES
    public static let blockRules = [
        "twitter.com/i/jot",
        "dmm.com/latest/js/dmm.tracking",
        "doubleclick.net",
        "googletagmanager.com/",
        "facebook.com",
        "pics.dmm.com/",
        "/uikit"
    ]

    // MARK: - JS snippets (verbatim from Constants.java)

    /// ADD_VIEWPORT_META
    public static let viewportMetaScript = #"var metaTag=document.createElement('meta');metaTag.name='viewport',metaTag.content='width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=0',document.getElementsByTagName('head')[0].appendChild(metaTag);"#

    /// MUTE_SEND_DMM (%d placeholder: 1 = mute, 0 = unmute)
    public static let muteSendDMM = #"(function(){var msg={sound:%d};var origin="*";var game_frame=document.getElementById("game_frame");if(game_frame!=null){game_frame.contentWindow.postMessage(msg,origin)};return "done"})()"#

    /// MUTE_SEND_OOI (%d placeholder)
    public static let muteSendOOI = #"(function(){var msg={sound:%d};var origin="*";var game_frame=document.getElementById("externalswf");if(game_frame!=null){game_frame.contentWindow.postMessage(msg,origin)};return "done"})()"#

    /// MUTE_LISTEN (leading newline preserved from source)
    public static let muteListen = "\n" + #"window.addEventListener("message",function(e){(e.data.sound!=null)&&(global_mute=e.data.sound,Howler.mute(global_mute),(!global_mute&&gb_h&&gb_h&&!gb_h.playing())&&gb_h.play())});"#

    /// CAPTURE_SEND_DMM
    public static let captureSendDMM = #"(function(){var msg={capture:true};var origin="*";var doc=document.getElementById("game_frame");if(doc){doc.contentWindow.postMessage(msg,origin)}else{document.getElementsByTagName("iframe")[0].contentWindow.postMessage(msg,origin)};return"done"})()"#

    /// CAPTURE_SEND_OOI
    public static let captureSendOOI = #"(function(){var msg={capture:true};var origin="*";var doc=document.getElementById("externalswf");if(doc){doc.contentWindow.postMessage(msg,origin)}else{document.getElementsByTagName("iframe")[0].contentWindow.postMessage(msg,origin)};return"done"})()"#

    /// CAPTURE_LISTEN — Android bridge `GotoBrowser.kcs_process_canvas_dataurl(dataurl)`
    /// replaced with the iOS webkit message handler.
    public static let captureListen = #"window.addEventListener("message",function(e){if(e.data.capture!=null){(async function(){{let canvas=document.querySelector('canvas');requestAnimationFrame(()=>{{if(canvas!=null){let dataurl=canvas.toDataURL('image/png');window.webkit.messageHandlers.gotoBrowser.postMessage({type:"capture",data:dataurl});}}});}})();}});"#

    /// ADJUST_SCRIPT
    public static let adjustScript = #"(()=>{const t="data-game-resize-init",e=1200;if(document.documentElement.hasAttribute(t))return;document.documentElement.setAttribute(t,"true");const n=()=>{const t=document.querySelector(".gamesResetStyle");if(!t)return!1;const n=document.createElement("style");n.textContent=".gamesResetStyle>main{margin:0!important;padding:0!important}.gamesResetStyle>:not(main){display:none!important}#game_frame{transform-origin:top left}",document.head.appendChild(n);const i=document.getElementById("game_frame");if(!i)return!1;const o=()=>{console.log("innerWidth:",window.innerWidth),i.style.transform=`scale(${window.innerWidth/e})`};let r=0;const a=()=>{cancelAnimationFrame(r),r=requestAnimationFrame(o)};return window.addEventListener("resize",a,{passive:!0}),o(),!0},i=new MutationObserver((()=>{n()&&i.disconnect()}));i.observe(document.body,{childList:!0,subtree:!0}),n()})();"#

    /// AUTOCOMPLETE_DMM (%s placeholders: login id, password)
    public static let autocompleteDMM = #"function v(e,t){let o=Object.getOwnPropertyDescriptor(e,"value").set,s=Object.getPrototypeOf(e),l=Object.getOwnPropertyDescriptor(s,"value").set;o&&o!==l?l.call(e,t):o.call(e,t)}if(document.forms.loginForm!=undefined){v(document.forms.loginForm.elements.login_id,"%s"),document.forms.loginForm.elements.login_id.dispatchEvent(new Event("input",{bubbles:!0})),v(document.forms.loginForm.elements.password,"%s"),document.forms.loginForm.elements.password.dispatchEvent(new Event("input",{bubbles:!0}));}"#

    /// AUTOCOMPLETE_OOI (%s placeholders: login id, password)
    public static let autocompleteOOI = #"$('input[name="login_id"]').val("%s");$('input[name="password"]').val("%s");"#

    /// DMM_COOKIE ({date} placeholder: expiry date string)
    public static let dmmCookieScript = #"document.cookie='ckcy_remedied_check="ec_mrnhbtk";expires={date};path=/;domain=.dmm.com';document.cookie='ckcy=1;path=/;domain=.dmm.com;expires={date};path=/;domain=.dmm.com';"#

    // MARK: - iOS-specific additions

    /// Periodically reports JS heap usage to the native side (memory warning feature).
    public static let memoryProbeScript = #"setInterval(function(){try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.gotoBrowser){var m=(performance&&performance.memory)?performance.memory.usedJSHeapSize/1048576:0;window.webkit.messageHandlers.gotoBrowser.postMessage({type:"memory",jsHeapMB:m});}}catch(e){}},10000);"#
}
