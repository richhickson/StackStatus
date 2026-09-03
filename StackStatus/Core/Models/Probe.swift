import Foundation

/// A reachability check a vendor can declare alongside its status feed.
enum ProbeSpec: Codable, Hashable, Sendable {
    case httpsHead(url: URL)
    case tcp(host: String, port: Int)
    case dns(host: String, resolver: String?)

    private enum CodingKeys: String, CodingKey { case type, url, host, port, resolver }

    private enum Kind: String, Codable {
        case httpsHead = "https_head"
        case tcp
        case dns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .httpsHead:
            self = .httpsHead(url: try c.decode(URL.self, forKey: .url))
        case .tcp:
            self = .tcp(host: try c.decode(String.self, forKey: .host), port: try c.decode(Int.self, forKey: .port))
        case .dns:
            self = .dns(
                host: try c.decode(String.self, forKey: .host),
                resolver: try c.decodeIfPresent(String.self, forKey: .resolver)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .httpsHead(let url):
            try c.encode(Kind.httpsHead, forKey: .type)
            try c.encode(url, forKey: .url)
        case .tcp(let host, let port):
            try c.encode(Kind.tcp, forKey: .type)
            try c.encode(host, forKey: .host)
            try c.encode(port, forKey: .port)
        case .dns(let host, let resolver):
            try c.encode(Kind.dns, forKey: .type)
            try c.encode(host, forKey: .host)
            try c.encodeIfPresent(resolver, forKey: .resolver)
        }
    }

    /// Short human readable form for the UI.
    var label: String {
        switch self {
        case .httpsHead(let url): return "HEAD \(url.host ?? url.absoluteString)"
        case .tcp(let host, let port): return "TCP \(host):\(port)"
        case .dns(let host, let resolver):
            if let resolver { return "DNS \(host) via \(resolver)" }
            return "DNS \(host)"
        }
    }
}

/// The outcome of running one probe once.
struct ProbeResult: Hashable, Sendable {
    var spec: ProbeSpec
    var ok: Bool
    /// Seconds. Nil when the probe failed before a measurement was possible.
    var latency: TimeInterval?
    var detail: String?
    var checkedAt: Date

    init(spec: ProbeSpec, ok: Bool, latency: TimeInterval? = nil, detail: String? = nil, checkedAt: Date = Date()) {
        self.spec = spec
        self.ok = ok
        self.latency = latency
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

/// The three always on checks that are not tied to any vendor.
struct BaselineResult: Hashable, Sendable {
    var gateway: ProbeResult?
    var dns: ProbeResult?
    var internet: ProbeResult?
    var checkedAt: Date

    /// The verdict engine treats the baseline as failing when the known good
    /// HTTPS target cannot be reached. Gateway and DNS are shown to the user
    /// so they can see where the chain breaks.
    var ok: Bool { internet?.ok ?? false }

    static let empty = BaselineResult(gateway: nil, dns: nil, internet: nil, checkedAt: .distantPast)
}
