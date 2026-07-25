import Foundation

public enum BlockRules {
    public static func isBlocked(urlString: String) -> Bool {
        BrowserConstants.blockRules.contains { urlString.contains($0) }
    }
    /// 从 BrowserConstants.blockRules 派生的域名片段（单一事实源）：
    /// 不含 "/" 的规则整体作为域名规则；含 "/" 的规则取其 host 部分
    /// （如 "pics.dmm.com/" → "pics.dmm.com"，"dmm.com/latest/..." → "dmm.com"）。
    /// host 部分为空（如 "/uikit"）的规则不参与 host 匹配。
    private static let hostFragments: [String] = BrowserConstants.blockRules.compactMap { rule in
        let fragment = rule.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return fragment.isEmpty ? nil : fragment
    }

    public static func isBlocked(host: String) -> Bool {
        // CONNECT 场景只有 host：对派生的域名片段做包含匹配
        hostFragments.contains { host.contains($0) }
    }
}
