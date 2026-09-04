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
        var delay: TimeInterval = 0
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

    static func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], fixture: String, delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        stubs[URL(string: url)!] = Stub(status: status, headers: headers, body: Fixtures.data(fixture), delay: delay)
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

    private let stopped = NSLock()
    private var isStopped = false

    override func startLoading() {
        Self.record(request)
        guard let stub = Self.lookup(request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.stopped.lock()
            let cancelled = self.isStopped
            self.stopped.unlock()
            guard !cancelled else { return }
            if let error = stub.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if self.request.httpMethod != "HEAD" { self.client?.urlProtocol(self, didLoad: stub.body) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stopped.lock()
        isStopped = true
        stopped.unlock()
    }
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
