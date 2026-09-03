import Foundation
import XCTest
@testable import StackStatus

/// Serves canned responses so no test touches the network. Register stubs by
/// exact URL; unmatched requests fail with a connection error.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var status: Int
        var headers: [String: String]
        var body: Data
        var error: Error?
    }

    nonisolated(unsafe) private static var stubs: [URL: Stub] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs = [:]
        recorded = []
    }

    static func stub(_ url: URL, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = Stub(status: status, headers: headers, body: body)
    }

    static func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        stub(URL(string: url)!, status: status, headers: headers, body: body)
    }

    static func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], fixture: String) {
        stub(url, status: status, headers: headers, body: Fixtures.data(fixture))
    }

    static func stubJSON(_ url: String, status: Int = 200, headers: [String: String] = [:], json: String) {
        stub(url, status: status, headers: ["Content-Type": "application/json"].merging(headers) { $1 }, body: Data(json.utf8))
    }

    static func fail(_ url: String, error: Error) {
        lock.lock(); defer { lock.unlock() }
        stubs[URL(string: url)!] = Stub(status: 0, headers: [:], body: Data(), error: error)
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func requests(for url: String) -> [URLRequest] {
        requests.filter { $0.url?.absoluteString == url }
    }

    private static func lookup(_ url: URL?) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        guard let url else { return nil }
        return stubs[url]
    }

    private static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let stub = Self.lookup(request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum Fixtures {
    private final class Token {}

    static func url(_ name: String) -> URL {
        let bundle = Bundle(for: Token.self)
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let base = parts[0]
        let ext = parts.count > 1 ? parts[1] : nil
        if let url = bundle.url(forResource: base, withExtension: ext)
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        fatalError("Missing fixture \(name)")
    }

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: url(name))
    }

    static func string(_ name: String) -> String {
        String(decoding: data(name), as: UTF8.self)
    }
}

/// A client wired to the mock protocol.
func makeMockClient() -> HTTPClient {
    HTTPClient(session: HTTPClient.makeSession(protocolClasses: [MockURLProtocol.self]))
}

func makeVendor(_ id: String = "acme", platform: Platform, base: String = "https://status.acme.test", feed: String? = nil, probes: [ProbeSpec] = []) -> Vendor {
    Vendor(id: id, name: id.capitalized, platform: platform, baseURL: URL(string: base)!, feedURL: feed.flatMap(URL.init(string:)), probes: probes)
}
