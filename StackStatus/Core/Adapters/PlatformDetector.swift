import Foundation

/// Guesses which platform a status page runs on by probing the known endpoint
/// shapes. Used when adding a vendor from the settings window.
struct PlatformDetector: Sendable {
    struct Detection: Hashable, Sendable {
        var platform: Platform
        /// Set for `.feed`: the URL that answered.
        var feedURL: URL?
    }

    static let feedPaths = ["/history.atom", "/feed.atom", "/feed.rss", "/history.rss", "/rss", "/feed", "/atom.xml", "/rss.xml", "/feed.xml"]

    let http: HTTPFetching

    init(http: HTTPFetching) {
        self.http = http
    }

    /// Steps run in order and stop at the first hit. incident.io comes before
    /// Statuspage because incident.io pages also serve a Statuspage compatible
    /// status.json.
    func detect(baseURL rawBase: URL) async -> Detection? {
        let base = Self.normalise(rawBase)

        if let data = try? await http.get(base.appendingStatusPath(IncidentIOAdapter.summaryPath), conditional: false).data,
           let json = try? data.jsonObject(), json["ongoing_incidents"] != nil {
            return Detection(platform: .incidentio, feedURL: nil)
        }

        if let data = try? await http.get(base.appendingStatusPath(StatuspageAdapter.statusPath), conditional: false).data,
           let json = try? data.jsonObject(), json.object("status")?.string("indicator") != nil {
            return Detection(platform: .statuspage, feedURL: nil)
        }

        for path in Self.feedPaths {
            let url = base.appendingStatusPath(path)
            if let feed = await feedDetection(at: url) { return feed }
        }

        // The base URL itself may be a feed, or an HTML page that advertises one.
        if case .success(let data, _, let contentType)? = try? await http.get(base, conditional: false) {
            if FeedAdapter.looksLikeFeed(data, contentType: contentType), (try? FeedAdapter.parse(data)) != nil {
                return Detection(platform: .feed, feedURL: base)
            }
            if let html = String(data: data, encoding: .utf8),
               let advertised = Self.advertisedFeedURL(inHTML: html, base: base),
               let feed = await feedDetection(at: advertised) {
                return feed
            }
        }
        return nil
    }

    private func feedDetection(at url: URL) async -> Detection? {
        guard case .success(let data, _, let contentType)? = try? await http.get(url, conditional: false) else { return nil }
        guard FeedAdapter.looksLikeFeed(data, contentType: contentType), (try? FeedAdapter.parse(data)) != nil else { return nil }
        return Detection(platform: .feed, feedURL: url)
    }

    /// Strip path, query and fragment so probes hit the page origin.
    static func normalise(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = url.host
        components.port = url.port
        return components.url ?? url
    }

    /// Find `<link rel="alternate" type="application/rss+xml" href="...">` in HTML.
    static func advertisedFeedURL(inHTML html: String, base: URL) -> URL? {
        let pattern = #"<link\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange]).lowercased()
            guard tag.contains("alternate"), tag.contains("rss+xml") || tag.contains("atom+xml") else { continue }
            guard let href = attribute("href", in: tag) else { continue }
            if let url = URL(string: href, relativeTo: base)?.absoluteURL { return url }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
}
