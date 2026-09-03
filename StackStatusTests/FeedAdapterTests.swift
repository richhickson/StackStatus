import XCTest
@testable import StackStatus

final class FeedAdapterTests: XCTestCase {
    /// Just after the fixtures were captured, so "within 24 hours" holds for the newest entries.
    private let captureTime = DateParsing.parse("2026-09-03T21:00:00Z")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: Parsing

    func testParsesStatuspageAtom() throws {
        let items = try FeedAdapter.parse(Fixtures.data("statuspage_history.atom"))
        XCTAssertEqual(items.count, 4)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.title, "Incident with Grok Copilot AI Model Provider")
        XCTAssertEqual(first.link?.host, "www.githubstatus.com")
        XCTAssertNotNil(first.date)
        XCTAssertTrue(first.body.contains("Resolved"))
        XCTAssertNil(first.status)
    }

    func testParsesStatuspageRSS() throws {
        let items = try FeedAdapter.parse(Fixtures.data("statuspage_history.rss"))
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first?.title, "Incident with Grok Copilot AI Model Provider")
        XCTAssertNotNil(items.first?.date)
        XCTAssertNotNil(items.first?.link)
    }

    func testParsesIncidentIOAtomWithCDATA() throws {
        let items = try FeedAdapter.parse(Fixtures.data("incidentio_feed.atom"))
        XCTAssertEqual(items.count, 4)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.title, "Elevated errors across ChatGPT and Codex")
        XCTAssertTrue(first.body.contains("Status: Resolved"))
        XCTAssertEqual(first.link?.absoluteString, "https://status.openai.com//incidents/01M1KWEDH417T2CF44YYHZDFCR")
    }

    func testParsesMicrosoftRSSWithStatusElement() throws {
        let items = try FeedAdapter.parse(Fixtures.data("microsoft_feed_mac_available.rss"))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.status, "Available")
        XCTAssertEqual(items.first?.title, "Microsoft Admin Center")
        XCTAssertEqual(items.first?.date, DateParsing.parse("2026-09-03T20:53:00Z"))
    }

    func testRejectsNonFeedXML() {
        XCTAssertThrowsError(try FeedAdapter.parse(Data("<html><body>hi</body></html>".utf8)))
        XCTAssertThrowsError(try FeedAdapter.parse(Data("{\"not\": \"xml\"}".utf8)))
    }

    // MARK: Snapshots

    func testAllResolvedHistoryIsOperational() throws {
        let s = try FeedAdapter.snapshot(from: Fixtures.data("statuspage_history.atom"), now: captureTime)
        XCTAssertEqual(s.state, .operational)
        XCTAssertTrue(s.incidents.isEmpty)
    }

    func testIncidentIOResolvedIsOperational() throws {
        let s = try FeedAdapter.snapshot(from: Fixtures.data("incidentio_feed.atom"), now: captureTime)
        XCTAssertEqual(s.state, .operational)
    }

    /// Rewrites only the first entry of a feed so it reads as unresolved.
    private func makeFirstEntryActive(_ feed: String, entryTag: String, replacements: [(String, String)]) -> String {
        let parts = feed.components(separatedBy: entryTag)
        guard parts.count > 2 else { return feed }
        var first = parts[1]
        for (from, to) in replacements { first = first.replacingOccurrences(of: from, with: to) }
        return ([parts[0], first] + parts[2...]).joined(separator: entryTag)
    }

    func testIncidentIOActiveEntryIsDegraded() throws {
        let atom = makeFirstEntryActive(Fixtures.string("incidentio_feed.atom"), entryTag: "<entry>", replacements: [
            ("Status: Resolved", "Status: Investigating"),
            ("resolved", "being investigated"),
        ])
        let s = try FeedAdapter.snapshot(from: Data(atom.utf8), now: captureTime)
        XCTAssertEqual(s.state, .degraded)
        XCTAssertEqual(s.incidents.count, 1)
        XCTAssertEqual(s.primaryIncident?.title, "Elevated errors across ChatGPT and Codex")
    }

    private var statuspageAtomWithActiveFirstEntry: String {
        makeFirstEntryActive(Fixtures.string("statuspage_history.atom"), entryTag: "<entry>", replacements: [
            ("Resolved", "Monitoring"),
            ("resolved", "mitigated"),
        ])
    }

    func testStatuspageActiveEntryIsDegraded() throws {
        let s = try FeedAdapter.snapshot(from: Data(statuspageAtomWithActiveFirstEntry.utf8), now: captureTime)
        XCTAssertEqual(s.state, .degraded)
        XCTAssertEqual(s.incidents.count, 1)
        XCTAssertEqual(s.primaryIncident?.title, "Incident with Grok Copilot AI Model Provider")
    }

    func testOldUnmarkedEntryIsNotActive() throws {
        let twoDaysLater = captureTime.addingTimeInterval(2 * 24 * 3600)
        let s = try FeedAdapter.snapshot(from: Data(statuspageAtomWithActiveFirstEntry.utf8), now: twoDaysLater)
        XCTAssertEqual(s.state, .operational)
    }

    func testMicrosoftAvailableIsOperational() throws {
        let s = try FeedAdapter.snapshot(from: Fixtures.data("microsoft_feed_mac_available.rss"), now: captureTime)
        XCTAssertEqual(s.state, .operational)
    }

    func testMicrosoftDegradationIsDegradedRegardlessOfAge() throws {
        let aWeekLater = captureTime.addingTimeInterval(7 * 24 * 3600)
        let s = try FeedAdapter.snapshot(from: Fixtures.data("microsoft_feed_mac_degraded.rss"), now: aWeekLater)
        XCTAssertEqual(s.state, .degraded)
        XCTAssertEqual(s.primaryIncident?.title, "Users may be unable to access the Microsoft 365 admin center")
        XCTAssertEqual(s.primaryIncident?.status, "Service degradation")
    }

    func testMaintenanceTitleMapsToMaintenance() throws {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>t</title>
        <item><title>Scheduled maintenance on the API</title><link>https://x.test/1</link>
        <pubDate>Thu, 03 Sep 2026 20:00:00 GMT</pubDate><description>We will be doing work.</description></item>
        </channel></rss>
        """
        let s = try FeedAdapter.snapshot(from: Data(rss.utf8), now: captureTime)
        XCTAssertEqual(s.state, .maintenance)
        XCTAssertEqual(s.incidents.first?.isMaintenance, true)
    }

    // MARK: Fetch

    func testFetchRequiresFeedURL() async {
        let vendor = makeVendor(platform: .feed)
        do {
            _ = try await FeedAdapter().fetch(vendor, using: makeMockClient(), conditional: false)
            XCTFail("expected an error")
        } catch AdapterError.missingFeedURL {
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchUsesFeedURL() async throws {
        let feed = "https://status.acme.test/api/feed/mac"
        MockURLProtocol.stub(feed, headers: ["Content-Type": "application/rss+xml"], fixture: "microsoft_feed_mac_available.rss")
        let vendor = makeVendor(platform: .feed, feed: feed)
        guard case .snapshot(let s) = try await FeedAdapter().fetch(vendor, using: makeMockClient(), conditional: false) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(s.state, .operational)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.absoluteString, feed)
    }
}
