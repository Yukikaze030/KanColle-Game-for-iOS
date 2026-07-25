import Foundation

/// Resolves the small, immutable resources bundled with the app that must
/// replace selected browser responses.
public struct AssetReplacer {
    private enum ResourceSource {
        case bundle(Bundle, subdirectory: String?)
        case directory(URL)
    }

    private struct Match {
        let resourceName: String
        let mimeType: String
    }

    private let source: ResourceSource

    /// Creates a replacer backed by an application or test bundle.
    ///
    /// Xcode's synchronized `Game` folder copies the files from
    /// `Game/BundleAssets` into the root of the built application bundle.
    /// A subdirectory remains injectable for other bundle layouts.
    public init(bundle: Bundle = .main, resourceSubdirectory: String? = nil) {
        source = .bundle(bundle, subdirectory: resourceSubdirectory)
    }

    /// Creates a replacer backed by an explicit resource directory.
    ///
    /// This initializer lets package tests use isolated fixtures without
    /// depending on the host application's main bundle.
    public init(resourceDirectory: URL) {
        source = .directory(resourceDirectory.standardizedFileURL)
    }

    /// Returns replacement bytes and their response MIME type when `path`
    /// exactly matches one of the supported browser resources.
    public func replacement(forPath path: String) -> (Data, String)? {
        guard let match = Self.match(for: path),
              let url = resourceURL(named: match.resourceName),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else {
            return nil
        }
        return (data, match.mimeType)
    }

    private func resourceURL(named name: String) -> URL? {
        switch source {
        case let .bundle(bundle, subdirectory):
            return bundle.url(forResource: name, withExtension: nil, subdirectory: subdirectory)
        case let .directory(directory):
            let candidate = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory else { return nil }
            return candidate
        }
    }

    private static func match(for rawPath: String) -> Match? {
        guard let path = normalizedPath(rawPath) else { return nil }

        switch path {
        case let value where value.hasSuffix("/gadget_html5/script/rollover.js"):
            return Match(resourceName: "rollover.js", mimeType: "application/javascript")
        case let value where value.hasSuffix("/gadget_html5/js/kcs_cda.js"):
            return Match(resourceName: "kcs_cda.js", mimeType: "application/javascript")
        case let value where value.hasSuffix("/html/maintenance.html"):
            return Match(resourceName: "maintenance.html", mimeType: "text/html")
        case let value where value.hasSuffix("/html/maintenance.png"):
            return Match(resourceName: "maintenance.png", mimeType: "image/png")
        default:
            break
        }

        guard let fileName = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        else {
            return nil
        }

        switch fileName {
        case "A-OTF-UDShinGoPro-Light.woff2", "A-OTF-UDShinGoPro-Regular.woff2":
            return Match(resourceName: fileName, mimeType: "font/woff2")
        case "tweenjs.min.js", "tweenjs-0.6.2.min.js":
            return Match(resourceName: "tweenjs-0.6.2.min.js", mimeType: "application/javascript")
        case "ooi.css":
            return Match(resourceName: "ooi.css", mimeType: "text/css")
        default:
            return nil
        }
    }

    private static func normalizedPath(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty,
              !rawPath.contains("\0"),
              !rawPath.contains("\\")
        else {
            return nil
        }

        let path: String
        if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
            guard let components = URLComponents(string: rawPath),
                  components.host != nil
            else {
                return nil
            }
            path = components.percentEncodedPath
        } else {
            let end = rawPath.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rawPath.endIndex
            path = String(rawPath[..<end])
        }

        let decodedSegments = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard path.hasPrefix("/"),
              !decodedSegments.contains(".."),
              !decodedSegments.contains(".")
        else {
            return nil
        }
        return path
    }
}
