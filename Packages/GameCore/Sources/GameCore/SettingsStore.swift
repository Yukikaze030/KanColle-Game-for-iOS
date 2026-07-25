import Foundation

/// UserDefaults-backed settings store. Preference keys match GotoBrowser's
/// Constants.java (pref_connector, pref_silent, ...) where applicable.
public struct SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// PREF_CURSOR_MODE_TOUCH = "1" / PREF_CURSOR_MODE_MOUSE = "2"
    public enum CursorMode: String, Sendable {
        case touch = "1"
        case mouse = "2"
    }

    public var connector: BrowserConstants.Connector {
        get { BrowserConstants.Connector(rawValue: defaults.string(forKey: "pref_connector") ?? "") ?? .dmm }
        set { defaults.set(newValue.rawValue, forKey: "pref_connector") }
    }

    public var cacheEnabled: Bool {
        get { defaults.object(forKey: "pref_cache") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref_cache") }
    }

    public var silentStart: Bool {
        get { defaults.bool(forKey: "pref_silent") }
        set { defaults.set(newValue, forKey: "pref_silent") }
    }

    public var muteMode: Bool {
        get { defaults.bool(forKey: "pref_mutemode") }
        set { defaults.set(newValue, forKey: "pref_mutemode") }
    }

    public var alterGadget: Bool {
        get { defaults.bool(forKey: "pref_alter_gadget") }
        set { defaults.set(newValue, forKey: "pref_alter_gadget") }
    }

    public var alterGadgetEndpoint: String {
        get { defaults.string(forKey: "pref_alter_endpoint") ?? BrowserConstants.defaultAlterGadgetURL }
        set { defaults.set(newValue, forKey: "pref_alter_endpoint") }
    }

    public var legacyRenderer: Bool {
        get { defaults.object(forKey: "pref_legacy_renderer") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref_legacy_renderer") }
    }

    /// Enables HTTPS inspection for game-server hosts after the local root CA
    /// has been installed and explicitly trusted by the user.
    public var mitmEnabled: Bool {
        get { defaults.object(forKey: "pref_mitm_enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref_mitm_enabled") }
    }

    public var subtitleLocale: String {
        get { defaults.string(forKey: "pref_subtitle_locale") ?? "scn" }
        set { defaults.set(newValue, forKey: "pref_subtitle_locale") }
    }

    public var subtitleEnabled: Bool {
        get { defaults.bool(forKey: "pref_showcc") }
        set { defaults.set(newValue, forKey: "pref_showcc") }
    }

    public var subtitleFontSize: Int {
        get { defaults.object(forKey: "pref_subtitle_size") as? Int ?? BrowserConstants.defaultSubtitleFontSize }
        set { defaults.set(newValue, forKey: "pref_subtitle_size") }
    }

    public var cursorMode: CursorMode {
        get { CursorMode(rawValue: defaults.string(forKey: "pref_cursor_mode") ?? "1") ?? .touch }
        set { defaults.set(newValue.rawValue, forKey: "pref_cursor_mode") }
    }

    public var keepScreenOn: Bool {
        get { defaults.bool(forKey: "pref_keepmode") }
        set { defaults.set(newValue, forKey: "pref_keepmode") }
    }

    public var downloadRetry: Bool {
        get { defaults.object(forKey: "pref_retry") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref_retry") }
    }

    public var memoryWarnEnabled: Bool {
        get { defaults.object(forKey: "pref_mem_warn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pref_mem_warn") }
    }

    /// 0 = auto threshold (computed from device memory at runtime).
    public var memoryWarnThresholdMB: Int {
        get { defaults.object(forKey: "pref_mem_warn_mb") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "pref_mem_warn_mb") }
    }

    /// Setting `nil` removes the key (UserDefaults.removeObject semantics).
    public var latestURL: String? {
        get { defaults.string(forKey: "pref_latest_url") }
        set { defaults.set(newValue, forKey: "pref_latest_url") }
    }
}
