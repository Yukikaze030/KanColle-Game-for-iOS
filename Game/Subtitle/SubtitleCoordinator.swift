import Combine
import Foundation
import GameCore

@MainActor
final class SubtitleCoordinator: ObservableObject {
    @Published private(set) var currentMatch: SubtitleMatch?

    private let settings: SettingsStore
    private let store: SubtitleStore?
    private var matcher: VoiceLineMatcher?
    private var shipGraphs: [[String: Any]] = []
    private var ships: [[String: Any]] = []
    private var loadedLocale: SubtitleLocale?
    private var loadTask: Task<Void, Never>?
    private var pendingVoiceEvent: ResourceVoiceEvent?

    init(settings: SettingsStore) {
        self.settings = settings
        let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("subtitle", isDirectory: true)
        self.store = try? SubtitleStore(cacheDirectory: cacheDirectory)
        if settings.subtitleEnabled {
            loadTask = Task { [weak self] in
                await self?.loadCatalog(updateFromNetwork: true)
                self?.finishLoading()
            }
        }
    }

    deinit {
        loadTask?.cancel()
    }

    func receiveAPIResponse(endpoint: String, response: String) {
        guard settings.subtitleEnabled,
              endpoint.contains("api_start2"),
              let data = Self.svdata(from: response),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let apiData = root["api_data"] as? [String: Any]
        else { return }
        shipGraphs = apiData["api_mst_shipgraph"] as? [[String: Any]] ?? []
        ships = apiData["api_mst_ship"] as? [[String: Any]] ?? []
        matcher?.loadMasterData(shipGraphs: shipGraphs, ships: ships)
    }

    func receiveVoiceResource(_ event: ResourceVoiceEvent) {
        guard settings.subtitleEnabled else {
            currentMatch = nil
            return
        }
        let desiredLocale = Self.locale(from: settings.subtitleLocale)
        if loadedLocale != desiredLocale {
            pendingVoiceEvent = event
            if loadTask == nil {
                loadTask = Task { [weak self] in
                    await self?.loadCatalog(updateFromNetwork: true)
                    self?.finishLoading()
                }
            }
            return
        }
        match(event)
    }

    private func finishLoading() {
        loadTask = nil
        if let pendingVoiceEvent {
            self.pendingVoiceEvent = nil
            match(pendingVoiceEvent)
        }
    }

    private func match(_ event: ResourceVoiceEvent) {
        guard let matcher else { return }
        let url = event.url.absoluteString
        let size = String(event.byteCount)
        let result: SubtitleMatch?
        switch Self.locale(from: settings.subtitleLocale).provider {
        case .kc3:
            result = matcher.matchKC3(
                url: url,
                path: event.url.path,
                voiceSize: size
            )
        case .kcwiki:
            result = matcher.matchKCWiki(url: url, path: event.url.path)
        }
        if let result {
            currentMatch = result
        }
    }

    private func loadCatalog(updateFromNetwork: Bool) async {
        guard let store else { return }
        let locale = Self.locale(from: settings.subtitleLocale)

        await installCachedCatalog(from: store, locale: locale)

        if updateFromNetwork {
            // Updates are best-effort. Existing valid disk data remains in use
            // when the device is offline or the provider is unavailable.
            try? await store.update(locale: locale)
            if locale.provider == .kc3 {
                try? await store.updateKC3QuoteSizes()
            }
            await installCachedCatalog(from: store, locale: locale)
        }
    }

    private func installCachedCatalog(
        from store: SubtitleStore,
        locale: SubtitleLocale
    ) async {
        let quotes = try? await store.cachedQuotes(for: locale)
        let sizes = try? await store.cachedQuoteSizes()
        guard let labels = Self.bundleData(named: "quotes_label", ext: "json"),
              let newMatcher = try? VoiceLineMatcher(
                  quoteLabelData: labels,
                  quoteSizeData: sizes ?? nil,
                  kc3QuoteData: locale.provider == .kc3 ? quotes ?? nil : nil,
                  kcwikiQuoteData: locale.provider == .kcwiki ? quotes ?? nil : nil
              )
        else { return }
        newMatcher.loadMasterData(shipGraphs: shipGraphs, ships: ships)
        matcher = newMatcher
        loadedLocale = locale
    }

    private static func locale(from rawValue: String) -> SubtitleLocale {
        switch rawValue.lowercased() {
        case "en": return .english
        case "kr", "ko": return .korean
        case "jp", "ja": return .japanese
        case "tcn", "zh-tw", "zh_tw": return .traditionalChinese
        default: return .simplifiedChinese
        }
    }

    private static func svdata(from response: String) -> Data? {
        let trimmed = response.hasPrefix("svdata=")
            ? String(response.dropFirst("svdata=".count))
            : response
        return trimmed.data(using: .utf8)
    }

    private static func bundleData(named name: String, ext: String) -> Data? {
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "BundleAssets"
            )
        ]
        return candidates.compactMap { $0 }.first.flatMap {
            try? Data(contentsOf: $0, options: .mappedIfSafe)
        }
    }
}
