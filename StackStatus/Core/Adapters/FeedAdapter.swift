import Foundation

/// One entry from an RSS 2.0 or Atom feed.
struct FeedItem: Hashable, Sendable {
    var id: String
    var title: String
    var link: URL?
    var date: Date?
    var body: String
    /// Non standard per item status element, as used by Microsoft's feed.
    var status: String?
}

/// Universal fallback: any status page with a feed. Fidelity is limited
/// because a feed cannot express severity, so an active item shows as
/// degraded (or maintenance when the title says so).
struct FeedAdapter: StatusFeedAdapter {
    let platform = Platform.feed

    /// How far back an undated or unmarked item still counts as active.
    static let lookback: TimeInterval = 24 * 60 * 60

    /// Values of a `<status>` element that mean "nothing wrong".
    static let healthyStatuses: Set<String> = [
        "available", "operational", "resolved", "healthy", "service restored", "completed", "false positive", "restored",
    ]

    /// Substrings in title or body that mean the item is finished.
    static let resolvedMarkers: [String] = [
        "status: resolved", "status: completed", "<strong>resolved</strong>", "<strong>completed</strong>",
        "has been resolved", "this incident has been resolved", "service restored", "resolved -", "completed -",
        "[resolved]", "(resolved)",
    ]

    static let maintenanceMarkers: [String] = ["maintenance", "scheduled work"]

    func fetch(_ vendor: Vendor, using http: HTTPFetching, conditional: Bool) async throws -> FetchOutcome {
        guard let feedURL = vendor.feedURL else { throw AdapterError.missingFeedURL }
        guard case .success(let data, _, _) = try await http.get(feedURL, conditional: conditional) else {
            return .unchanged
        }
        return .snapshot(try Self.snapshot(from: data, now: Date()))
    }

    static func snapshot(from data: Data, now: Date) throws -> FeedSnapshot {
        let items = try parse(data)
        let active = items.filter { isActive($0, now: now) }
        let incidents = active.map { item in
            Incident(
                id: item.id,
                title: item.title,
                url: item.link,
                status: item.status,
                impact: nil,
                startedAt: item.date,
                updatedAt: item.date,
                isMaintenance: looksLikeMaintenance(item)
            )
        }
        let states = incidents.map { $0.isMaintenance ? VendorState.maintenance : .degraded }
        let state = states.isEmpty ? VendorState.operational : VendorState.worst(of: states)
        return FeedSnapshot(state: state, incidents: incidents, description: state == .operational ? "No active items in feed" : nil)
    }

    static func isActive(_ item: FeedItem, now: Date) -> Bool {
        if let status = item.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !status.isEmpty {
            return !healthyStatuses.contains(status)
        }
        guard let date = item.date, now.timeIntervalSince(date) < lookback, date.timeIntervalSince(now) < lookback else {
            return false
        }
        let text = (item.title + " " + item.body).lowercased()
        return !resolvedMarkers.contains { text.contains($0) }
    }

    static func looksLikeMaintenance(_ item: FeedItem) -> Bool {
        let title = item.title.lowercased()
        return maintenanceMarkers.contains { title.contains($0) }
    }

    static func parse(_ data: Data) throws -> [FeedItem] {
        let parser = FeedXMLParser(data: data)
        guard parser.run() else { throw AdapterError.malformed("feed XML") }
        guard parser.sawFeedRoot else { throw AdapterError.malformed("feed: not RSS or Atom") }
        return parser.items
    }

    /// Cheap test used by the platform detector before parsing.
    static func looksLikeFeed(_ data: Data, contentType: String?) -> Bool {
        if let type = contentType?.lowercased(), type.contains("rss") || type.contains("atom") { return true }
        guard let head = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")
    }
}

/// Minimal RSS 2.0 and Atom parser on top of Foundation's XMLParser.
final class FeedXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private(set) var items: [FeedItem] = []
    private(set) var sawFeedRoot = false

    private var inItem = false
    private var current: [String: String] = [:]
    private var currentLink: URL?
    private var text = ""
    private var depthInsideItem = 0

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
        parser.shouldProcessNamespaces = false
    }

    func run() -> Bool {
        parser.parse()
        // XMLParser reports an error for trailing junk even after items were found; accept that.
        return parser.parserError == nil || !items.isEmpty
    }

    private static func localName(_ qualified: String) -> String {
        if let colon = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: colon)...]).lowercased() }
        return qualified.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = Self.localName(elementName)
        if !sawFeedRoot, name == "rss" || name == "feed" || name == "rdf" { sawFeedRoot = true }
        if !inItem, name == "item" || name == "entry" {
            inItem = true
            current = [:]
            currentLink = nil
            depthInsideItem = 0
            return
        }
        guard inItem else { return }
        depthInsideItem += 1
        text = ""
        if name == "link", let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? "alternate"
            if rel == "alternate", currentLink == nil { currentLink = URL(string: href) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inItem, let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.localName(elementName)
        guard inItem else { return }
        if name == "item" || name == "entry" {
            inItem = false
            items.append(makeItem())
            return
        }
        depthInsideItem -= 1
        // Only record direct children of the item; nested markup inside content is text.
        guard depthInsideItem == 0 else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "link":
            if currentLink == nil, let url = URL(string: value) { currentLink = url }
        case "title", "id", "guid", "updated", "published", "pubdate", "summary", "content", "description", "status", "encoded":
            if current[name] == nil || !value.isEmpty { current[name] = value }
        default:
            break
        }
        text = ""
    }

    private func makeItem() -> FeedItem {
        let title = current["title"] ?? ""
        let id = current["id"] ?? current["guid"] ?? currentLink?.absoluteString ?? title
        let date = DateParsing.parse(current["updated"]) ?? DateParsing.parse(current["published"]) ?? DateParsing.parse(current["pubdate"])
        let body = current["content"] ?? current["encoded"] ?? current["summary"] ?? current["description"] ?? ""
        return FeedItem(id: id, title: title, link: currentLink, date: date, body: body, status: current["status"])
    }
}
