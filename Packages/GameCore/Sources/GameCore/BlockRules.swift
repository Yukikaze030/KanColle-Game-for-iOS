import Foundation

public enum BlockRules {
    public static func isBlocked(urlString: String) -> Bool {
        BrowserConstants.blockRules.contains { urlString.contains($0) }
    }
    public static func isBlocked(host: String) -> Bool {
        // CONNECT 场景只有 host：匹配包含 host 的规则片段
        ["doubleclick.net", "googletagmanager.com", "facebook.com"].contains { host.contains($0) }
    }
}
