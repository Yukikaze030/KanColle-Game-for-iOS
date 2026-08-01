import CryptoKit
import Foundation

/// A bounded, complete HTTP response returned by ResourceCache's injectable
/// transport. Tests inject a deterministic closure; production uses URLSession.
public struct ResourceFetchResult: Sendable {
    public let statusCode: Int
    public let headers: [(String, String)]
    public let body: Data

    public init(statusCode: Int, headers: [(String, String)], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first {
            $0.0.caseInsensitiveCompare(name) == .orderedSame
        }?.1
    }
}

public typealias ResourceFetcher = (
    _ request: URLRequest,
    _ maximumBodyBytes: Int
) throws -> ResourceFetchResult

/// A successfully served voice resource. The event is emitted for both disk
/// cache hits and network responses so subtitle matching does not depend on
/// the resource's storage source.
public struct ResourceVoiceEvent: Equatable, Sendable {
    public let url: URL
    public let path: String
    public let byteCount: Int

    public init(url: URL, path: String, byteCount: Int) {
        self.url = url
        self.path = path
        self.byteCount = max(0, byteCount)
    }
}

/// Synchronous resource replacement/cache layer used by LocalProxyServer's
/// synchronous `onGameResourceRequest` callback.
///
/// Files are addressed by SHA-256 rather than request paths, so untrusted URL
/// components can never escape `cacheDirectory`.
public final class ResourceCache: @unchecked Sendable {
    public enum FetchError: Error, Equatable {
        case invalidResponse
        case responseTooLarge(limit: Int)
        case timedOut
    }

    public static let defaultMaximumResponseBytes = 32 * 1_024 * 1_024

    private let cacheDirectory: URL
    private let versionStore: VersionStore
    private let settings: SettingsStore
    private let assetReplacer: AssetReplacer
    private let scriptPatcher: ScriptPatcher?
    private let fetcher: ResourceFetcher
    private let now: () -> Date
    private let maximumResponseBytes: Int
    private let fileManager: FileManager
    private let onVoiceResource: (@Sendable (ResourceVoiceEvent) -> Void)?

    public init(
        cacheDir: URL,
        versionStore: VersionStore,
        settings: SettingsStore,
        assetReplacer: AssetReplacer = AssetReplacer(),
        scriptPatcher: ScriptPatcher? = ScriptPatcher(),
        maximumResponseBytes: Int = ResourceCache.defaultMaximumResponseBytes,
        now: @escaping () -> Date = Date.init,
        onVoiceResource: (@Sendable (ResourceVoiceEvent) -> Void)? = nil,
        fetcher: @escaping ResourceFetcher = { request, limit in
            try ResourceCache.urlSessionFetch(
                request,
                maximumBodyBytes: limit
            )
        }
    ) {
        self.cacheDirectory = cacheDir.standardizedFileURL
        self.versionStore = versionStore
        self.settings = settings
        self.assetReplacer = assetReplacer
        self.scriptPatcher = scriptPatcher
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.now = now
        self.fetcher = fetcher
        self.fileManager = .default
        self.onVoiceResource = onVoiceResource
        try? fileManager.createDirectory(
            at: self.cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Returns a complete local response, or nil when the proxy should use its
    /// ordinary passthrough path.
    public func response(
        for head: ProxyHTTPParser.HTTPRequestHead
    ) -> ResourceResponse? {
        let method = head.method.uppercased()
        guard method == "GET" || method == "HEAD",
              let originalURL = requestURL(for: head)
        else {
            return nil
        }

        // Bundled immutable assets intentionally have priority over host
        // filtering, matching GotoBrowser's replacement pipeline.
        if let (body, mimeType) = assetReplacer.replacement(forPath: head.path) {
            return ResourceResponse(
                statusCode: 200,
                headers: [("Content-Type", mimeType)],
                body: method == "HEAD" ? Data() : body
            )
        }

        guard Self.isGameServerHost(head.host) else {
            return nil
        }

        let upstreamURL = mappedGadgetURL(for: originalURL, path: head.path)
            ?? originalURL
        let isCrossHostMapping =
            upstreamURL.host?.lowercased() != originalURL.host?.lowercased()
        let cacheKey = Self.cacheKey(for: originalURL)
        let fileURL = cacheFileURL(forKey: cacheKey, originalURL: originalURL)
        let requestVersion = Self.version(from: originalURL)

        let storedRow: VersionRow?
        if settings.cacheEnabled {
            storedRow = (try? versionStore.get(key: cacheKey)) ?? nil
        } else {
            storedRow = nil
        }

        if let row = storedRow,
           Self.versionsMatch(stored: row.version, requested: requestVersion),
           fileManager.isReadableFile(atPath: fileURL.path),
           CachePolicy.isFresh(
               .init(
                   fetchedAt: row.fetchedAt,
                   lastModified: row.lastModified,
                   maxAgeSeconds: row.maxAgeSeconds
               ),
               at: now()
           ),
           let body = boundedFileData(at: fileURL) {
            emitVoiceEventIfNeeded(
                originalURL: originalURL,
                path: head.path,
                bodyByteCount: body.count,
                headers: []
            )
            return cachedResponse(
                body: body,
                originalURL: originalURL,
                method: method
            )
        }

        let canRevalidate = settings.cacheEnabled
            && Self.versionsMatch(
                stored: storedRow?.version,
                requested: requestVersion
            )
            && fileManager.isReadableFile(atPath: fileURL.path)
        var request = makeRequest(
            url: upstreamURL,
            sourceHead: head,
            lastModified: canRevalidate ? storedRow?.lastModified : nil,
            isCrossHostMapping: isCrossHostMapping
        )
        request.httpMethod = method

        guard let fetched = try? fetcher(request, maximumResponseBytes),
              fetched.body.count <= maximumResponseBytes
        else {
            // P1 retry UI is intentionally deferred. Returning nil lets the
            // proxy's normal upstream path proceed regardless of retry setting.
            _ = settings.downloadRetry
            return nil
        }

        if fetched.statusCode == 304,
           canRevalidate,
           let existingRow = storedRow,
           let body = boundedFileData(at: fileURL) {
            try? versionStore.put(
                key: cacheKey,
                version: existingRow.version,
                lastModified: fetched.header("Last-Modified")
                    ?? existingRow.lastModified,
                maxAgeSeconds: CachePolicy.parseMaxAge(
                    fetched.header("Cache-Control")
                ) ?? existingRow.maxAgeSeconds
            )
            emitVoiceEventIfNeeded(
                originalURL: originalURL,
                path: head.path,
                bodyByteCount: body.count,
                headers: fetched.headers
            )
            return cachedResponse(
                body: body,
                originalURL: originalURL,
                method: method,
                extraHeaders: fetched.headers
            )
        }

        let response = resourceResponse(
            from: fetched,
            originalURL: originalURL,
            method: method
        )
        if (200..<300).contains(fetched.statusCode) {
            emitVoiceEventIfNeeded(
                originalURL: originalURL,
                path: head.path,
                bodyByteCount: fetched.body.count,
                headers: fetched.headers
            )
        }
        guard method == "GET",
              fetched.statusCode == 200,
              settings.cacheEnabled
        else {
            return response
        }

        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try fetched.body.write(
                to: fileURL,
                options: Data.WritingOptions.atomic
            )
            try versionStore.put(
                key: cacheKey,
                version: requestVersion,
                lastModified: fetched.header("Last-Modified"),
                maxAgeSeconds: CachePolicy.parseMaxAge(
                    fetched.header("Cache-Control")
                )
            )
        } catch {
            // A fetched response remains useful even if the cache volume is
            // temporarily unwritable. A later request can try again.
        }
        return response
    }

    private func emitVoiceEventIfNeeded(
        originalURL: URL,
        path: String,
        bodyByteCount: Int,
        headers: [(String, String)]
    ) {
        guard let onVoiceResource,
              Self.isVoiceResource(path: originalURL.path)
        else { return }
        let headerLength = headers.first {
            $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame
        }.flatMap { Int($0.1) }
        let size = bodyByteCount > 0 ? bodyByteCount : max(0, headerLength ?? 0)
        onVoiceResource(.init(url: originalURL, path: path, byteCount: size))
    }

    // MARK: - Request mapping

    private func requestURL(
        for head: ProxyHTTPParser.HTTPRequestHead
    ) -> URL? {
        guard Self.isSafeOriginPath(head.path),
              let encodedHost = Self.normalizedHost(head.host)
        else {
            return nil
        }
        let scheme = head.port == 443 ? "https" : "http"
        let defaultPort = head.port == 443 ? 443 : 80
        let portPart = head.port == defaultPort ? "" : ":\(head.port)"
        return URL(string: "\(scheme)://\(encodedHost)\(portPart)\(head.path)")
    }

    private func mappedGadgetURL(for originalURL: URL, path: String) -> URL? {
        guard settings.alterGadget,
              path.contains("gadget_html5"),
              var endpoint = URLComponents(
                  string: settings.alterGadgetEndpoint
              ),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "https",
              endpoint.host != nil,
              endpoint.user == nil,
              endpoint.password == nil
        else {
            return nil
        }

        let endpointPath = endpoint.percentEncodedPath
        let prefix = endpointPath.hasSuffix("/")
            ? endpointPath
            : endpointPath + "/"
        let originalComponents = URLComponents(
            url: originalURL,
            resolvingAgainstBaseURL: false
        )
        let encodedSourcePath = originalComponents?.percentEncodedPath
            ?? originalURL.path
        let sourcePath = encodedSourcePath.hasPrefix("/")
            ? String(encodedSourcePath.dropFirst())
            : encodedSourcePath
        endpoint.percentEncodedPath = prefix + sourcePath
        endpoint.percentEncodedQuery = originalComponents?.percentEncodedQuery
        endpoint.fragment = nil
        return endpoint.url
    }

    private func makeRequest(
        url: URL,
        sourceHead: ProxyHTTPParser.HTTPRequestHead,
        lastModified: String?,
        isCrossHostMapping: Bool
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        let alwaysExcluded = Set([
            "host", "connection", "proxy-connection", "content-length",
            "transfer-encoding", "range", "if-modified-since",
            "accept-encoding", "keep-alive", "upgrade", "te", "trailer"
        ])
        // Gadget 绕行会跨 host。只复制不会携带身份、来源或会话状态的
        // 展示协商头，绝不把游戏服务器凭证发送给第三方缓存端点。
        let crossHostAllowlist = Set([
            "accept", "accept-language", "user-agent"
        ])
        for (name, value) in sourceHead.headers
        where !alwaysExcluded.contains(name.lowercased())
            && (!isCrossHostMapping
                || crossHostAllowlist.contains(name.lowercased())) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let lastModified {
            request.setValue(
                lastModified,
                forHTTPHeaderField: "If-Modified-Since"
            )
        }
        return request
    }

    // MARK: - Disk cache

    func cacheFileURL(forKey key: String, originalURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = Self.safeExtension(from: originalURL.path)
        return cacheDirectory.appendingPathComponent(
            ext.map { "\(digest).\($0)" } ?? digest,
            isDirectory: false
        )
    }

    private func boundedFileData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size >= 0,
              size <= maximumResponseBytes
        else {
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= maximumResponseBytes
        else {
            return nil
        }
        return data
    }

    private func cachedResponse(
        body: Data,
        originalURL: URL,
        method: String,
        extraHeaders: [(String, String)] = []
    ) -> ResourceResponse {
        var headers = Self.filteredResponseHeaders(extraHeaders)
        if !headers.contains(where: {
            $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame
        }) {
            headers.append((
                "Content-Type",
                Self.mimeType(for: originalURL.path)
            ))
        }
        return ResourceResponse(
            statusCode: 200,
            headers: headers,
            body: method == "HEAD" ? Data() : transformedBody(body, for: originalURL)
        )
    }

    private func resourceResponse(
        from fetched: ResourceFetchResult,
        originalURL: URL,
        method: String
    ) -> ResourceResponse {
        ResourceResponse(
            statusCode: fetched.statusCode,
            headers: Self.filteredResponseHeaders(fetched.headers),
            body: method == "HEAD"
                ? Data()
                : transformedBody(fetched.body, for: originalURL)
        )
    }

    private func transformedBody(_ body: Data, for originalURL: URL) -> Data {
        guard originalURL.path.hasSuffix("/kcs2/js/main.js"),
              let scriptPatcher
        else {
            return body
        }
        let cursorMode: ScriptPatcher.CursorMode =
            settings.cursorMode == .touch ? .touch : .mouse
        return scriptPatcher.patchMainScript(
            body,
            options: .init(
                muteOnStart: settings.silentStart,
                cursorMode: cursorMode,
                adjustsGameLayout: true,
                unlocksFPS: settings.fpsUnlockEnabled,
                showsCriticalDamage: settings.critDisplayEnabled
            )
        )
    }

    private static func filteredResponseHeaders(
        _ headers: [(String, String)]
    ) -> [(String, String)] {
        let excluded = Set([
            "connection", "proxy-connection", "keep-alive",
            "transfer-encoding", "content-length", "content-encoding",
            "upgrade", "trailer"
        ])
        return headers.filter { !excluded.contains($0.0.lowercased()) }
    }

    private static func cacheKey(for url: URL) -> String {
        var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    private static func version(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "ver" })?
            .value
    }

    private static func versionsMatch(
        stored: String?,
        requested: String?
    ) -> Bool {
        stored == requested
    }

    private static func safeExtension(from path: String) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty,
              ext.count <= 10,
              ext.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
              })
        else {
            return nil
        }
        return ext
    }

    private static func normalizedHost(_ rawHost: String) -> String? {
        let host = rawHost.lowercased()
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
                      .contains($0)
              }),
              !host.contains(".."),
              !host.hasPrefix("."),
              !host.hasSuffix(".")
        else {
            return nil
        }
        return host
    }

    private static func isGameServerHost(_ rawHost: String) -> Bool {
        guard let host = normalizedHost(rawHost) else { return false }
        return host == "kancolle-server.com"
            || host.hasSuffix(".kancolle-server.com")
    }

    private static func isSafeOriginPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\"),
              !path.contains("#")
        else {
            return false
        }
        let rawPath = path.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        return rawPath.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy {
                let decoded = String($0).removingPercentEncoding ?? String($0)
                return decoded != "." && decoded != ".."
            }
    }

    private static func mimeType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "js": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func isVoiceResource(path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".mp3")
            && (lowercased.contains("/kcs/sound/kc")
                || lowercased.contains("/kcs2/resources/voice/titlecall_"))
    }

    // MARK: - Production native transport

    public static func urlSessionFetch(
        _ request: URLRequest,
        maximumBodyBytes: Int
    ) throws -> ResourceFetchResult {
        let delegate = BoundedURLSessionDelegate(
            maximumBodyBytes: maximumBodyBytes
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        task.resume()

        let timeout = max(1, request.timeoutInterval) + 5
        guard delegate.wait(timeout: timeout) else {
            task.cancel()
            session.invalidateAndCancel()
            throw FetchError.timedOut
        }
        session.finishTasksAndInvalidate()
        return try delegate.result()
    }
}

final class BoundedURLSessionDelegate: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let maximumBodyBytes: Int
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var body = Data()
    private var completionError: Error?
    private var exceededLimit = false

    init(maximumBodyBytes: Int) {
        self.maximumBodyBytes = max(1, maximumBodyBytes)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionError = ResourceCache.FetchError.invalidResponse
            completionHandler(.cancel)
            return
        }
        self.response = response
        if response.expectedContentLength > Int64(maximumBodyBytes) {
            exceededLimit = true
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return }
        guard data.count <= maximumBodyBytes - body.count else {
            exceededLimit = true
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 禁止自动重定向。否则可信 Gadget 端点仍可能把经过筛选的请求
        // 导向攻击者 host；调用方只接收原始 3xx 响应。
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        completionError = completionError ?? error
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func result() throws -> ResourceFetchResult {
        lock.lock()
        defer { lock.unlock() }
        if exceededLimit {
            throw ResourceCache.FetchError.responseTooLarge(
                limit: maximumBodyBytes
            )
        }
        if let completionError {
            throw completionError
        }
        guard let response else {
            throw ResourceCache.FetchError.invalidResponse
        }
        let headers = response.allHeaderFields.compactMap {
            key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key, String(describing: value))
        }
        return ResourceFetchResult(
            statusCode: response.statusCode,
            headers: headers,
            body: body
        )
    }
}
