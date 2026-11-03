import Foundation

/// Ordered list of Sparkle appcast URLs (highest priority first). Sparkle itself only takes one
/// `SUFeedURL`, so the app bakes the full list into Info.plist (`AVUpdateFeedURLs`) and, before each
/// check, hands Sparkle the first feed that is currently serving a valid appcast.
public enum UpdateFeeds {
    public static let infoPlistKey = "AVUpdateFeedURLs"

    /// Parses `Resources/UpdateFeedBases.txt`-style text into feed base URLs: blank lines and `#`
    /// comments ignored, https only, trailing slashes trimmed, duplicates dropped, order kept.
    public static func parseBases(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            while line.hasSuffix("/") { line.removeLast() }
            guard line.lowercased().hasPrefix("https://"), URL(string: line)?.host != nil,
                  seen.insert(line).inserted else { continue }
            result.append(line)
        }
        return result
    }

    /// Feed URLs recorded in an Info.plist dictionary; non-https or malformed entries are skipped.
    public static func urls(fromInfo info: [String: Any]) -> [URL] {
        let strings = (info[infoPlistKey] as? [String]) ?? []
        return strings.compactMap { string in
            guard string.lowercased().hasPrefix("https://"), let url = URL(string: string) else { return nil }
            return url
        }
    }

    /// First feed for which `isServing` is true. When none is reachable (offline, outage) the
    /// primary is returned so Sparkle reports its usual error against the preferred address.
    public static func select(from feeds: [URL], isServing: (URL) -> Bool) -> URL? {
        feeds.first(where: isServing) ?? feeds.first
    }

    /// Blocking probe — call off the main thread. True only for a 200 response whose body looks like
    /// an appcast, so a 404 page, captive portal or empty Pages site counts as down.
    public static func isServingAppcast(_ url: URL, timeout: TimeInterval = 8) -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
               let body = String(data: data.prefix(4096), encoding: .utf8) {
                ok = body.contains("<rss") || body.contains("<channel")
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel(); return false }
        return ok
    }
}
