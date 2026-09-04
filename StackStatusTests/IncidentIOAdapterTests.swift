import XCTest
@testable import StackStatus

final class IncidentIOAdapterTests: XCTestCase {
    private let base = "https://status.acme.test"
    private var summaryURL: String { base + "/api/v1/summary" }
    private var proxyURL: String { base + "/proxy/status.acme.test" }
    private let adapter = IncidentIOAdapter()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func snapshot() async throws -> FeedSnapshot {
        let outcome = try await adapter.fetch(makeVendor(platform: .incidentio, base: base), using: makeMockClient(), conditional: false)
        guard case .snapshot(let s) = outcome else { XCTFail("expected a snapshot"); throw AdapterError.malformed("test") }
        return s
    }

    func testComponentStatusMapping() {
        XCTAssertEqual(IncidentIOAdapter.state(forComponentStatus: "operational"), .operational)
        XCTAssertEqual(IncidentIOAdapter.state(forComponentStatus: "degraded_performance"), .degraded)
        XCTAssertEqual(IncidentIOAdapter.state(forComponentStatus: "partial_outage"), .partialOutage)
        XCTAssertEqual(IncidentIOAdapter.state(forComponentStatus: "full_outage"), .majorOutage)
        XCTAssertEqual(IncidentIOAdapter.state(forComponentStatus: "under_maintenance"), .maintenance)
        XCTAssertEqual(IncidentIOAdapter.state(forComponentStatus: "something_new"), .degraded)
    }

    func testQuietSummaryIsOperational() async throws {
        MockURLProtocol.stub(summaryURL, fixture: "incidentio_v1_summary_none.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .operational)
        XCTAssertTrue(s.incidents.isEmpty)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testDegradedIncident() async throws {
        MockURLProtocol.stub(summaryURL, fixture: "incidentio_v1_summary_degraded.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .degraded)
        let incident = try XCTUnwrap(s.primaryIncident)
        XCTAssertEqual(incident.title, "Elevated errors across ChatGPT and Codex")
        XCTAssertEqual(incident.status, "investigating")
        XCTAssertEqual(incident.url?.absoluteString, "\(base)/incidents/01M1KWEDH417T2CF44YYHZDFCR")
        XCTAssertNotNil(incident.startedAt)
        XCTAssertFalse(incident.isMaintenance)
    }

    func testPartialOutage() async throws {
        MockURLProtocol.stub(summaryURL, fixture: "incidentio_v1_summary_partial.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .partialOutage)
    }

    func testFullOutageMapsToMajor() async throws {
        MockURLProtocol.stub(summaryURL, fixture: "incidentio_v1_summary_major.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .majorOutage)
    }

    func testMaintenanceOnly() async throws {
        MockURLProtocol.stub(summaryURL, fixture: "incidentio_v1_summary_maintenance.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .maintenance)
        XCTAssertEqual(s.incidents.first?.title, "Scheduled database maintenance")
        XCTAssertEqual(s.incidents.first?.isMaintenance, true)
    }

    func testFallsBackToProxyOn404() async throws {
        MockURLProtocol.stub(summaryURL, status: 404, body: Data("<html>not found</html>".utf8))
        MockURLProtocol.stub(proxyURL, fixture: "incidentio_proxy_summary_partial.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .partialOutage)
        XCTAssertEqual(s.primaryIncident?.title, "Elevated errors across ChatGPT and Codex")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testProxyQuiet() async throws {
        MockURLProtocol.stub(summaryURL, status: 404)
        MockURLProtocol.stub(proxyURL, fixture: "incidentio_proxy_summary_none.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .operational)
    }

    func testStartedAtIsEarliestUpdate() throws {
        let json = try Fixtures.data("incidentio_v1_summary_degraded.json").jsonObject()
        let s = try IncidentIOAdapter.parseSummary(json, pageURL: URL(string: base)!)
        // The fixture's earliest update was published at 14:43:00Z on 3 September 2026.
        XCTAssertEqual(s.primaryIncident?.startedAt, DateParsing.parse("2026-09-03T14:43:00Z"))
    }

    func testUnrelatedJSONThrows() {
        XCTAssertThrowsError(try IncidentIOAdapter.parseSummary(["page": ["id": "x"]], pageURL: URL(string: base)!))
    }
}
