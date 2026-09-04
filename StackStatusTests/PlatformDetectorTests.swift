import XCTest
@testable import StackStatus

final class PlatformDetectorTests: XCTestCase {
    private let base = URL(string: "https://status.acme.test")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func detect(_ url: URL? = nil) async -> PlatformDetector.Detection? {
        await PlatformDetector(http: makeMockClient()).detect(baseURL: url ?? base)
    }

    func testDetectsIncidentIO() async {
        MockURLProtocol.stub("https://status.acme.test/api/v1/summary", fixture: "incidentio_v1_summary_none.json")
        // incident.io pages also answer the Statuspage endpoint; incident.io must still win.
        MockURLProtocol.stub("https://status.acme.test/api/v2/status.json", fixture: "incidentio_v2_status.json")
        let d = await detect()
        XCTAssertEqual(d, PlatformDetector.Detection(platform: .incidentio, feedURL: nil))
    }

    func testDetectsStatuspage() async {
        MockURLProtocol.stub("https://status.acme.test/api/v1/summary", status: 404)
        MockURLProtocol.stub("https://status.acme.test/api/v2/status.json", fixture: "statuspage_status_none.json")
        let d = await detect()
        XCTAssertEqual(d, PlatformDetector.Detection(platform: .statuspage, feedURL: nil))
    }

    func testDetectsFeedByWellKnownPath() async {
        MockURLProtocol.stub("https://status.acme.test/history.atom", headers: ["Content-Type": "application/atom+xml"], fixture: "statuspage_history.atom")
        let d = await detect()
        XCTAssertEqual(d?.platform, .feed)
        XCTAssertEqual(d?.feedURL?.absoluteString, "https://status.acme.test/history.atom")
    }

    func testDetectsFeedAdvertisedInHTML() async {
        let html = """
        <html><head><title>Acme status</title>
        <link rel="alternate" type="application/rss+xml" title="Acme" href="/api/feed/mac">
        </head><body>hello</body></html>
        """
        MockURLProtocol.stub("https://status.acme.test", headers: ["Content-Type": "text/html"], body: Data(html.utf8))
        MockURLProtocol.stub("https://status.acme.test/api/feed/mac", headers: ["Content-Type": "application/rss+xml"], fixture: "microsoft_feed_mac_available.rss")
        let d = await detect()
        XCTAssertEqual(d?.platform, .feed)
        XCTAssertEqual(d?.feedURL?.absoluteString, "https://status.acme.test/api/feed/mac")
    }

    func testBaseURLThatIsItselfAFeed() async {
        MockURLProtocol.stub("https://status.acme.test", headers: ["Content-Type": "application/rss+xml"], fixture: "statuspage_history.rss")
        let d = await detect()
        XCTAssertEqual(d, PlatformDetector.Detection(platform: .feed, feedURL: base))
    }

    func testNormalisesPathAndQuery() async {
        MockURLProtocol.stub("https://status.acme.test/api/v2/status.json", fixture: "statuspage_status_none.json")
        let d = await detect(URL(string: "https://status.acme.test/incidents/123?x=1#top")!)
        XCTAssertEqual(d?.platform, .statuspage)
    }

    func testHTMLThatLooksLikeNothingReturnsNil() async {
        MockURLProtocol.stub("https://status.acme.test", headers: ["Content-Type": "text/html"], body: Data("<html><body>nope</body></html>".utf8))
        let d = await detect()
        XCTAssertNil(d)
    }

    func testEverythingUnreachableReturnsNil() async {
        let d = await detect()
        XCTAssertNil(d)
    }

    func testAdvertisedFeedParsing() {
        let html = #"<link rel="stylesheet" href="/a.css"><LINK REL="alternate" TYPE="application/atom+xml" HREF="https://feeds.acme.test/history.atom">"#
        let url = PlatformDetector.advertisedFeedURL(inHTML: html, base: base)
        XCTAssertEqual(url?.absoluteString, "https://feeds.acme.test/history.atom")
    }
}
