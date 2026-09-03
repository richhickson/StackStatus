import Foundation

/// One adapter per status page platform. Adapters are stateless: they take a
/// vendor and a client and return what the page says right now.
protocol StatusFeedAdapter: Sendable {
    var platform: Platform { get }

    /// Fetch the vendor's current state. `conditional` is false when the
    /// caller has no previous snapshot to fall back on, so the adapter must
    /// not send If-None-Match and must not return `.unchanged`.
    func fetch(_ vendor: Vendor, using http: HTTPFetching, conditional: Bool) async throws -> FetchOutcome
}

enum AdapterError: Error, CustomStringConvertible {
    case malformed(String)
    case missingFeedURL

    var description: String {
        switch self {
        case .malformed(let what): return "Could not parse \(what)"
        case .missingFeedURL: return "Vendor has no feed URL"
        }
    }
}

/// Registry mapping platforms to adapters.
enum Adapters {
    static let all: [Platform: any StatusFeedAdapter] = [
        .statuspage: StatuspageAdapter(),
        .incidentio: IncidentIOAdapter(),
        .feed: FeedAdapter(),
    ]

    static func adapter(for platform: Platform) -> any StatusFeedAdapter {
        all[platform] ?? FeedAdapter()
    }
}

/// Small helpers for walking JSONSerialization output without a model per endpoint.
typealias JSONObject = [String: Any]

extension Data {
    func jsonObject() throws -> JSONObject {
        guard let object = try JSONSerialization.jsonObject(with: self) as? JSONObject else {
            throw AdapterError.malformed("JSON object")
        }
        return object
    }

    func jsonArray() throws -> [Any] {
        guard let array = try JSONSerialization.jsonObject(with: self) as? [Any] else {
            throw AdapterError.malformed("JSON array")
        }
        return array
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func array(_ key: String) -> [JSONObject] { (self[key] as? [JSONObject]) ?? [] }
    func date(_ key: String) -> Date? { DateParsing.parse(string(key)) }
    func url(_ key: String) -> URL? { string(key).flatMap(URL.init(string:)) }
}

extension URL {
    /// Append a path to a base URL, tolerating a trailing slash on the base.
    func appendingStatusPath(_ path: String) -> URL {
        var base = absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? self
    }
}
