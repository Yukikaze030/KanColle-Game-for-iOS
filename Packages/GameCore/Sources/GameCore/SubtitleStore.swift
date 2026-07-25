import Foundation

public enum SubtitleLocale: String, CaseIterable, Sendable {
    case english = "en"
    case korean = "kr"
    case japanese = "jp"
    case simplifiedChinese = "zh-cn"
    case traditionalChinese = "zh-tw"

    public enum Provider: Sendable { case kc3, kcwiki }

    public var provider: Provider {
        switch self {
        case .english, .korean, .japanese: return .kc3
        case .simplifiedChinese, .traditionalChinese: return .kcwiki
        }
    }
}

public struct SubtitleFetchResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public typealias SubtitleFetcher = @Sendable (
    _ request: URLRequest,
    _ maximumBodyBytes: Int
) async throws -> SubtitleFetchResponse

/// Downloads subtitle catalogs and stores complete JSON documents atomically.
/// Network transport is injectable; production uses URLSession only.
public actor SubtitleStore {
    public enum StoreError: Error, Equatable, Sendable {
        case invalidURL
        case invalidHTTPStatus(Int)
        case responseTooLarge(limit: Int)
        case invalidJSON
        case missingVersion
        case cacheUnavailable
    }

    public struct RemoteVersion: Equatable, Sendable {
        public let value: String
        public let downloadURL: URL

        public init(value: String, downloadURL: URL) {
            self.value = value
            self.downloadURL = downloadURL
        }
    }

    public static let defaultMaximumResponseBytes = 16 * 1_024 * 1_024

    private let cacheDirectory: URL
    private let maximumResponseBytes: Int
    private let fetcher: SubtitleFetcher
    private let fileManager: FileManager

    public init(
        cacheDirectory: URL,
        maximumResponseBytes: Int = SubtitleStore.defaultMaximumResponseBytes,
        fetcher: SubtitleFetcher? = nil
    ) throws {
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.fetcher = fetcher ?? { request, limit in
            try await SubtitleStore.urlSessionFetch(
                request: request,
                maximumBodyBytes: limit
            )
        }
        self.fileManager = .default
        do {
            try fileManager.createDirectory(
                at: self.cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.cacheUnavailable
        }
    }

    public func cachedQuotes(for locale: SubtitleLocale) throws -> Data? {
        try boundedDataIfPresent(at: quotesFileURL(for: locale))
    }

    public func cachedQuoteSizes() throws -> Data? {
        try boundedDataIfPresent(at: quoteSizesFileURL)
    }

    public func latestVersion(for locale: SubtitleLocale) async throws -> RemoteVersion {
        switch locale.provider {
        case .kc3:
            let path = "data/\(locale.rawValue)/quotes.json"
            let checkURL = try makeURL(
                "https://api.github.com/repos/KC3Kai/kc3-translations/commits",
                queryItems: [URLQueryItem(name: "path", value: path)]
            )
            let response = try await fetch(checkURL)
            guard let array = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
                throw StoreError.invalidJSON
            }
            guard let commit = array.first?["sha"] as? String, !commit.isEmpty,
                  let downloadURL = URL(string:
                    "https://raw.githubusercontent.com/KC3Kai/kc3-translations/\(commit)/\(path)"
                  )
            else { throw StoreError.missingVersion }
            return RemoteVersion(value: commit, downloadURL: downloadURL)

        case .kcwiki:
            let response = try await fetch(try makeURL("https://api.kcwiki.moe/subtitles/version"))
            guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let version = Self.stringValue(object["version"]), !version.isEmpty,
                  let downloadURL = URL(string:
                    "https://api.kcwiki.moe/subtitles/\(locale.rawValue)"
                  )
            else { throw StoreError.missingVersion }
            return RemoteVersion(value: version, downloadURL: downloadURL)
        }
    }

    /// Downloads the selected catalog and only replaces the previous cache after
    /// validating that the new body is a top-level JSON object.
    @discardableResult
    public func update(locale: SubtitleLocale) async throws -> RemoteVersion {
        let version = try await latestVersion(for: locale)
        let response = try await fetch(version.downloadURL)
        try validateJSONObject(response.body)
        try atomicWrite(response.body, to: quotesFileURL(for: locale))
        try atomicWrite(Data(version.value.utf8), to: versionFileURL(for: locale))
        return version
    }

    public func cachedVersion(for locale: SubtitleLocale) throws -> String? {
        guard let data = try boundedDataIfPresent(at: versionFileURL(for: locale)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// KC3 quote-size metadata is versioned in the KC3Kai repository separately
    /// from translated quote files, matching the Android implementation.
    @discardableResult
    public func updateKC3QuoteSizes() async throws -> RemoteVersion {
        let path = "src/data/quotes_size.json"
        let checkURL = try makeURL(
            "https://api.github.com/repos/KC3Kai/KC3Kai/commits",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
        let check = try await fetch(checkURL)
        guard let array = try JSONSerialization.jsonObject(with: check.body) as? [[String: Any]],
              let commit = array.first?["sha"] as? String, !commit.isEmpty,
              let downloadURL = URL(string:
                "https://raw.githubusercontent.com/KC3Kai/KC3Kai/\(commit)/\(path)"
              )
        else { throw StoreError.missingVersion }
        let body = try await fetch(downloadURL).body
        try validateJSONObject(body)
        try atomicWrite(body, to: quoteSizesFileURL)
        try atomicWrite(Data(commit.utf8), to: quoteSizesVersionFileURL)
        return RemoteVersion(value: commit, downloadURL: downloadURL)
    }

    public func cachedQuoteSizesVersion() throws -> String? {
        guard let data = try boundedDataIfPresent(at: quoteSizesVersionFileURL) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func quotesFileURL(for locale: SubtitleLocale) -> URL {
        let filename: String
        switch locale.provider {
        case .kc3: filename = "quotes_\(locale.rawValue).json"
        case .kcwiki: filename = "quotes_kcwiki_\(locale.rawValue).json"
        }
        return cacheDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    public var quoteSizesFileURL: URL {
        cacheDirectory.appendingPathComponent("quotes_size.json", isDirectory: false)
    }

    private var quoteSizesVersionFileURL: URL {
        cacheDirectory.appendingPathComponent("quotes_size.version", isDirectory: false)
    }

    private func versionFileURL(for locale: SubtitleLocale) -> URL {
        cacheDirectory.appendingPathComponent(
            "\(quotesFileURL(for: locale).lastPathComponent).version",
            isDirectory: false
        )
    }

    private func fetch(_ url: URL) async throws -> SubtitleFetchResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Game-iOS", forHTTPHeaderField: "User-Agent")
        let response = try await fetcher(request, maximumResponseBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw StoreError.invalidHTTPStatus(response.statusCode)
        }
        guard response.body.count <= maximumResponseBytes else {
            throw StoreError.responseTooLarge(limit: maximumResponseBytes)
        }
        if let contentLength = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame
        }).flatMap({ Int($0.value) }), contentLength > maximumResponseBytes {
            throw StoreError.responseTooLarge(limit: maximumResponseBytes)
        }
        return response
    }

    private func boundedDataIfPresent(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > maximumResponseBytes {
            throw StoreError.responseTooLarge(limit: maximumResponseBytes)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumResponseBytes else {
            throw StoreError.responseTooLarge(limit: maximumResponseBytes)
        }
        return data
    }

    private func validateJSONObject(_ data: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw StoreError.invalidJSON
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            throw StoreError.cacheUnavailable
        }
    }

    private func makeURL(
        _ string: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents(string: string) else {
            throw StoreError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw StoreError.invalidURL }
        return url
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    public static func urlSessionFetch(
        request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> SubtitleFetchResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StoreError.invalidHTTPStatus(0)
        }
        guard data.count <= maximumBodyBytes else {
            throw StoreError.responseTooLarge(limit: maximumBodyBytes)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return SubtitleFetchResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: data
        )
    }
}
