import Foundation

/// In memory store of ETags per URL. Deliberately not persisted: a tag is
/// only useful while the parsed body it belongs to is still in memory, and
/// after a relaunch there is no such body, so sending an old tag would earn a
/// 304 with nothing to show.
actor ETagStore {
    private var tags: [URL: String] = [:]

    func tag(for url: URL) -> String? { tags[url] }
    func set(_ tag: String?, for url: URL) { tags[url] = tag }
    func clear(_ url: URL) { tags[url] = nil }
    func clearAll() { tags.removeAll() }
}

/// Result of a GET.
enum HTTPResponse: Sendable {
    /// The server answered 304 Not Modified to our If-None-Match.
    case notModified
    case success(data: Data, status: Int, contentType: String?)

    var data: Data? {
        if case .success(let data, _, _) = self { return data }
        return nil
    }
}

enum HTTPError: Error, Sendable, CustomStringConvertible {
    /// A non 2xx, non 304 status. `retryAfter` is parsed from the Retry-After header when present.
    case status(Int, retryAfter: TimeInterval?)
    case transport(String)
    case invalidResponse
    case cancelled

    var description: String {
        switch self {
        case .status(let code, _): return "HTTP \(code)"
        case .transport(let message): return message
        case .invalidResponse: return "Invalid response"
        case .cancelled: return "Cancelled"
        }
    }

    /// True for the responses that should trigger exponential backoff.
    var shouldBackOff: Bool {
        if case .status(let code, _) = self { return code == 429 || code >= 500 }
        return false
    }
}

/// The network surface the adapters and probes use, so tests can substitute a
/// client backed by `MockURLProtocol` and never touch the network.
protocol HTTPFetching: Sendable {
    /// GET with an optional conditional request. Only GET and HEAD exist on
    /// this type on purpose: the app never sends anything else.
    func get(_ url: URL, conditional: Bool) async throws -> HTTPResponse
    /// HEAD returning the status code and elapsed time. Any HTTP response at
    /// all counts as a reply, even 401 or 403.
    func head(_ url: URL) async throws -> (status: Int, latency: TimeInterval)
}

extension HTTPFetching {
    func get(_ url: URL) async throws -> HTTPResponse { try await get(url, conditional: true) }
}

/// One shared URLSession for the whole app: ephemeral, no cookies, no URL
/// cache, connection reuse on, 10 second request timeout.
final class HTTPClient: HTTPFetching, @unchecked Sendable {
    static let requestTimeout: TimeInterval = 10
    static let repositoryURL = "https://github.com/richhickson/StackStatus"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var userAgent: String { "StackStatus/\(version) (+\(repositoryURL))" }

    let session: URLSession
    let etags: ETagStore

    init(session: URLSession? = nil, etags: ETagStore = ETagStore()) {
        self.session = session ?? HTTPClient.makeSession()
        self.etags = etags
    }

    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json, application/atom+xml, application/rss+xml, application/xml;q=0.9, */*;q=0.5",
        ]
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config)
    }

    func get(_ url: URL, conditional: Bool) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if conditional, let tag = await etags.tag(for: url) {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        switch http.statusCode {
        case 304:
            return .notModified
        case 200..<300:
            await etags.set(http.value(forHTTPHeaderField: "ETag"), for: url)
            return .success(data: data, status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        default:
            throw HTTPError.status(http.statusCode, retryAfter: Self.retryAfter(from: http))
        }
    }

    func head(_ url: URL) async throws -> (status: Int, latency: TimeInterval) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let started = Date()
        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        return (http.statusCode, Date().timeIntervalSince(started))
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw HTTPError.cancelled
        } catch is CancellationError {
            throw HTTPError.cancelled
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    /// Retry-After may be a number of seconds or an HTTP date.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        if let date = DateParsing.parse(raw) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }
}
