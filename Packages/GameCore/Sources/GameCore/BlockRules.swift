import Foundation

public enum BlockRules {
    public static func isBlocked(urlString: String) -> Bool {
        BrowserConstants.blockRules.contains { urlString.contains($0) }
    }
    /// 从 BrowserConstants.blockRules 派生的 host 阻断片段（单一事实源）。
    /// 只有两类规则参与 host 阻断：
    ///   1. 纯域名规则（不含 "/"）：doubleclick.net、facebook.com
    ///   2. 域名+尾部斜杠规则：pics.dmm.com/、googletagmanager.com/
    /// 含路径的规则（dmm.com/latest/js/dmm.tracking、twitter.com/i/jot、/uikit）
    /// 是路径级阻断，不参与 host 阻断——否则会把 play.games.dmm.com 等正常域一起封掉。
    private static let hostFragments: [String] = BrowserConstants.blockRules.compactMap { rule in
        if !rule.contains("/") { return rule.isEmpty ? nil : rule }
        if rule.hasSuffix("/"), !rule.hasPrefix("/") {
            let host = String(rule.dropLast())
            return host.isEmpty ? nil : host
        }
        return nil
    }

    public static func isBlocked(host: String) -> Bool {
        // CONNECT 场景只有 host：对派生的域名片段做包含匹配
        hostFragments.contains { host.contains($0) }
    }
}
