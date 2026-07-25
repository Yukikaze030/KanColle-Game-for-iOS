import Foundation

public enum CachePolicy {
    public struct Entry: Equatable, Sendable {
        public let fetchedAt: Date
        public let lastModified: String?
        public let maxAgeSeconds: Int?

        public init(
            fetchedAt: Date,
            lastModified: String?,
            maxAgeSeconds: Int?
        ) {
            self.fetchedAt = fetchedAt
            self.lastModified = lastModified
            self.maxAgeSeconds = maxAgeSeconds
        }
    }

    public static func isFresh(_ entry: Entry, at now: Date) -> Bool {
        guard let maxAge = entry.maxAgeSeconds, maxAge > 0 else {
            return false
        }
        return now.timeIntervalSince(entry.fetchedAt) < TimeInterval(maxAge)
    }

    public static func parseMaxAge(_ cacheControl: String?) -> Int? {
        guard let cacheControl else {
            return nil
        }

        for directive in cacheControl.split(separator: ",", omittingEmptySubsequences: false) {
            let components = directive.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard components.count == 2,
                  components[0]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("max-age") == .orderedSame else {
                continue
            }

            var value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let seconds = Int(value), seconds >= 0 {
                return seconds
            }
        }
        return nil
    }
}
