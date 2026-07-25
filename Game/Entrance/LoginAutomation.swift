import Foundation
import WebKit
import GameCore

/// Login-page automation kept separate from the navigation delegate so it can be
/// attached when task 10 is wired into WebViewCoordinator.
@MainActor
final class LoginAutomation {
    enum AutomationError: LocalizedError {
        case javascriptEncodingFailed
        case cookieCreationFailed(String)
        case keychain(Error)
        case javascript(Error)

        var errorDescription: String? {
            switch self {
            case .javascriptEncodingFailed:
                return "登录信息无法安全编码为 JavaScript 字符串。"
            case .cookieCreationFailed(let name):
                return "无法创建 DMM Cookie：\(name)"
            case .keychain(let error):
                return error.localizedDescription
            case .javascript(let error):
                return "自动填充失败：\(error.localizedDescription)"
            }
        }
    }

    private let settings: SettingsStore
    private let keychain: KeychainStore
    private var reloadedForGoogle = false

    var onError: ((AutomationError) -> Void)?

    init(settings: SettingsStore = SettingsStore(), keychain: KeychainStore? = nil) {
        self.settings = settings
        self.keychain = keychain ?? KeychainStore()
    }

    func handlePageFinished(_ webView: WKWebView,
                            connector: BrowserConstants.Connector? = nil) {
        guard let url = webView.url else { return }
        let selectedConnector = connector ?? settings.connector
        let address = url.absoluteString.lowercased()

        if address.contains("accounts.google.com") {
            useGoogleUserAgentIfNeeded(webView)
            return
        }
        reloadedForGoogle = false
        restorePreferredUserAgent(webView)

        if BrowserConstants.dmmForeignMarkers.contains(where: address.contains) {
            installDMMRegionCookies(in: webView) { [weak webView] in
                webView?.load(URLRequest(url: selectedConnector.url))
            }
            return
        }

        if BrowserConstants.dmmLoginMarkers.contains(where: address.contains) {
            fillCredentials(in: webView, connector: .dmm, scriptBuilder: Self.dmmFillScript)
            return
        }

        switch selectedConnector {
        case .ooi where url.host?.lowercased().hasSuffix("ooi.moe") == true:
            fillCredentials(in: webView, connector: .ooi, scriptBuilder: Self.proxyFillScript)
        case .kanmoe where url.host?.lowercased().hasSuffix("kancolle.moe") == true:
            fillCredentials(in: webView, connector: .kanmoe, scriptBuilder: Self.proxyFillScript)
        default:
            break
        }
    }

    private func fillCredentials(
        in webView: WKWebView,
        connector: BrowserConstants.Connector,
        scriptBuilder: (String, String) throws -> String
    ) {
        do {
            guard let credentials = try keychain.load(for: connector) else { return }
            let script = try scriptBuilder(credentials.id, credentials.password)
            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error { self?.onError?(.javascript(error)) }
            }
        } catch let error as AutomationError {
            onError?(error)
        } catch {
            onError?(.keychain(error))
        }
    }

    private func useGoogleUserAgentIfNeeded(_ webView: WKWebView) {
        guard webView.customUserAgent != BrowserConstants.userAgentMobile else { return }
        webView.customUserAgent = BrowserConstants.userAgentMobile
        guard !reloadedForGoogle else { return }
        reloadedForGoogle = true
        webView.reload()
    }

    private func restorePreferredUserAgent(_ webView: WKWebView) {
        let preferred = settings.legacyRenderer
            ? BrowserConstants.userAgentIOSCanvas
            : BrowserConstants.userAgentDesktop
        if webView.customUserAgent == BrowserConstants.userAgentMobile {
            webView.customUserAgent = preferred
        }
    }

    private func installDMMRegionCookies(in webView: WKWebView,
                                         completion: @escaping () -> Void) {
        let cookieValues: [[HTTPCookiePropertyKey: Any]] = [
            [HTTPCookiePropertyKey.name: "ckcy", HTTPCookiePropertyKey.value: "1"],
            [HTTPCookiePropertyKey.name: "ckcy_remedied_check", HTTPCookiePropertyKey.value: "ec_mrnhbtk"]
        ]
        let properties: [[HTTPCookiePropertyKey: Any]] = cookieValues.map { values in
            var result = values
            result[.domain] = ".dmm.com"
            result[.path] = "/"
            result[.expires] = Date().addingTimeInterval(365 * 24 * 60 * 60)
            result[.secure] = "TRUE"
            return result
        }

        let cookies = properties.compactMap(HTTPCookie.init(properties:))
        guard cookies.count == properties.count else {
            onError?(.cookieCreationFailed("ckcy"))
            return
        }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    /// JSON serialization produces a quoted JavaScript string literal. This avoids
    /// interpolation/printf injection even for quotes, backslashes and newlines.
    private static func javaScriptStringLiteral(_ value: String) throws -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              var arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.first == "[", arrayLiteral.last == "]" else {
            throw AutomationError.javascriptEncodingFailed
        }
        arrayLiteral.removeFirst()
        arrayLiteral.removeLast()
        return arrayLiteral
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func dmmFillScript(id: String, password: String) throws -> String {
        let safeID = try javaScriptStringLiteral(id)
        let safePassword = try javaScriptStringLiteral(password)
        return """
        (() => {
          const setValue = (element, value) => {
            if (!element) return;
            const own = Object.getOwnPropertyDescriptor(element, "value")?.set;
            const inherited = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element), "value")?.set;
            (inherited && own !== inherited ? inherited : own)?.call(element, value);
            element.dispatchEvent(new Event("input", { bubbles: true }));
            element.dispatchEvent(new Event("change", { bubbles: true }));
          };
          const form = document.forms.loginForm;
          setValue(form?.elements?.login_id ?? document.querySelector('input[name="login_id"],input[type="email"]'), \(safeID));
          setValue(form?.elements?.password ?? document.querySelector('input[name="password"],input[type="password"]'), \(safePassword));
        })();
        """
    }

    private static func proxyFillScript(id: String, password: String) throws -> String {
        let safeID = try javaScriptStringLiteral(id)
        let safePassword = try javaScriptStringLiteral(password)
        return """
        (() => {
          const setValue = (selector, value) => {
            const element = document.querySelector(selector);
            if (!element) return;
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
            setter ? setter.call(element, value) : (element.value = value);
            element.dispatchEvent(new Event("input", { bubbles: true }));
            element.dispatchEvent(new Event("change", { bubbles: true }));
          };
          setValue('input[name="login_id"],input[name="username"],input[type="email"]', \(safeID));
          setValue('input[name="password"],input[type="password"]', \(safePassword));
        })();
        """
    }
}
