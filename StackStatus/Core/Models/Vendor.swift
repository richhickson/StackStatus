import Foundation

/// Which status page platform a vendor publishes on. Each case has an adapter.
enum Platform: String, Codable, CaseIterable, Sendable {
    case statuspage
    case incidentio
    case feed

    var label: String {
        switch self {
        case .statuspage: return "Atlassian Statuspage"
        case .incidentio: return "incident.io"
        case .feed: return "RSS or Atom feed"
        }
    }
}

/// One watched vendor, as stored in vendors.json.
struct Vendor: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var enabled: Bool
    var platform: Platform
    var baseURL: URL
    var incidentURL: URL?
    var feedURL: URL?
    var probes: [ProbeSpec]
    var notes: String?

    init(
        id: String,
        name: String,
        enabled: Bool = true,
        platform: Platform,
        baseURL: URL,
        incidentURL: URL? = nil,
        feedURL: URL? = nil,
        probes: [ProbeSpec] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.platform = platform
        self.baseURL = baseURL
        self.incidentURL = incidentURL
        self.feedURL = feedURL
        self.probes = probes
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, platform, baseURL, incidentURL, feedURL, probes, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        platform = try c.decode(Platform.self, forKey: .platform)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        incidentURL = try c.decodeIfPresent(URL.self, forKey: .incidentURL)
        feedURL = try c.decodeIfPresent(URL.self, forKey: .feedURL)
        probes = try c.decodeIfPresent([ProbeSpec].self, forKey: .probes) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    /// Where to send the user when they click an incident with no link of its own.
    var pageURL: URL { incidentURL ?? baseURL }
}

/// The on disk document. Vendors that fail to decode are skipped rather than
/// failing the whole file, so a future platform added by the community does
/// not break older builds.
struct VendorConfig: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var vendors: [Vendor]

    init(version: Int = VendorConfig.currentVersion, vendors: [Vendor]) {
        self.version = version
        self.vendors = vendors
    }

    private enum CodingKeys: String, CodingKey { case version, vendors }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? VendorConfig.currentVersion
        let entries = try c.decodeIfPresent([Lenient<Vendor>].self, forKey: .vendors) ?? []
        vendors = entries.compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(vendors, forKey: .vendors)
    }
}

/// Wraps a decodable so that one bad array element becomes nil instead of an error.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
