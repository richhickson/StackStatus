import XCTest
@testable import StackStatus

final class StatuspageAdapterTests: XCTestCase {
    private let base = "https://status.acme.test"
    private var statusURL: String { base + "/api/v2/status.json" }
    private var unresolvedURL: String { base + "/api/v2/incidents/unresolved.json" }
    private var maintenanceURL: String { base + "/api/v2/scheduled-maintenances/active.json" }
    private let adapter = StatuspageAdapter()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func fetch(conditional: Bool = false) async throws -> FetchOutcome {
        try await adapter.fetch(makeVendor(platform: .statuspage, base: base), using: makeMockClient(), conditional: conditional)
    }

    private func snapshot(conditional: Bool = false) async throws -> FeedSnapshot {
        guard case .snapshot(let s) = try await fetch(conditional: conditional) else {
            XCTFail("expected a snapshot"); throw AdapterError.malformed("test")
        }
        return s
    }

    func testIndicatorMapping() {
        XCTAssertEqual(StatuspageAdapter.state(forIndicator: "none"), .operational)
        XCTAssertEqual(StatuspageAdapter.state(forIndicator: "minor"), .degraded)
        XCTAssertEqual(StatuspageAdapter.state(forIndicator: "major"), .partialOutage)
        XCTAssertEqual(StatuspageAdapter.state(forIndicator: "critical"), .majorOutage)
        XCTAssertEqual(StatuspageAdapter.state(forIndicator: "maintenance"), .maintenance)
        XCTAssertEqual(StatuspageAdapter.state(forIndicator: "purple"), .unknown)
    }

    func testOperationalMakesOneRequestOnly() async throws {
        MockURLProtocol.stub(statusURL, fixture: "statuspage_status_none.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .operational)
        XCTAssertEqual(s.description, "All Systems Operational")
        XCTAssertTrue(s.incidents.isEmpty)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "GET")
    }

    func testMinorFetchesUnresolvedIncidents() async throws {
        MockURLProtocol.stub(statusURL, fixture: "statuspage_status_minor.json")
        MockURLProtocol.stub(unresolvedURL, fixture: "statuspage_unresolved_minor.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .degraded)
        XCTAssertEqual(s.incidents.count, 1)
        let incident = try XCTUnwrap(s.primaryIncident)
        XCTAssertEqual(incident.title, "Incorrect geo location for some Cloudflare WARP users")
        XCTAssertEqual(incident.status, "identified")
        XCTAssertEqual(incident.impact, "minor")
        XCTAssertEqual(incident.url?.absoluteString, "https://www.cloudflarestatus.com/incidents/9g65dxfbcjln")
        XCTAssertNotNil(incident.startedAt)
        XCTAssertFalse(incident.isMaintenance)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testMajorMapsToPartialOutage() async throws {
        MockURLProtocol.stub(statusURL, fixture: "statuspage_status_major.json")
        MockURLProtocol.stub(unresolvedURL, fixture: "statuspage_unresolved_major.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .partialOutage)
        XCTAssertEqual(s.primaryIncident?.title, "Elevated errors on Fable 5 due to upstream provider")
    }

    func testCriticalMapsToMajorOutage() async throws {
        MockURLProtocol.stub(statusURL, fixture: "statuspage_status_critical.json")
        MockURLProtocol.stub(unresolvedURL, fixture: "statuspage_unresolved_critical.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .majorOutage)
        XCTAssertEqual(s.primaryIncident?.title, "Incident with Copilot AI Model Providers")
        XCTAssertEqual(s.primaryIncident?.impact, "critical")
    }

    func testMaintenanceUsesActiveMaintenanceEndpoint() async throws {
        MockURLProtocol.stub(statusURL, fixture: "statuspage_status_maintenance.json")
        MockURLProtocol.stub(maintenanceURL, fixture: "statuspage_maintenance_active.json")
        let s = try await snapshot()
        XCTAssertEqual(s.state, .maintenance)
        XCTAssertEqual(s.incidents.count, 1)
        XCTAssertEqual(s.incidents.first?.title, "Codespaces Scheduled Maintenance")
        XCTAssertEqual(s.incidents.first?.isMaintenance, true)
        XCTAssertTrue(MockURLProtocol.requests(for: unresolvedURL).isEmpty)
    }

    func testIncidentDetailFailureStillReportsState() async throws {
        MockURLProtocol.stub(statusURL, fixture: "statuspage_status_minor.json")
        MockURLProtocol.stub(unresolvedURL, status: 500)
        let s = try await snapshot()
        XCTAssertEqual(s.state, .degraded)
        XCTAssertTrue(s.incidents.isEmpty)
    }

    func testNotModifiedReturnsUnchangedAndSendsIfNoneMatch() async throws {
        let client = makeMockClient()
        let vendor = makeVendor(platform: .statuspage, base: base)
        MockURLProtocol.stub(statusURL, headers: ["ETag": "W/\"abc\""], fixture: "statuspage_status_none.json")
        guard case .snapshot = try await adapter.fetch(vendor, using: client, conditional: false) else { return XCTFail() }
        XCTAssertNil(MockURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "first fetch is unconditional")

        MockURLProtocol.stub(statusURL, status: 304, headers: ["ETag": "W/\"abc\""])
        guard case .unchanged = try await adapter.fetch(vendor, using: client, conditional: true) else { return XCTFail("expected unchanged") }
        XCTAssertEqual(MockURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
    }

    func testUnconditionalFetchNeverSendsIfNoneMatch() async throws {
        let client = makeMockClient()
        let vendor = makeVendor(platform: .statuspage, base: base)
        MockURLProtocol.stub(statusURL, headers: ["ETag": "W/\"abc\""], fixture: "statuspage_status_none.json")
        _ = try await adapter.fetch(vendor, using: client, conditional: false)
        _ = try await adapter.fetch(vendor, using: client, conditional: false)
        XCTAssertNil(MockURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testServerErrorThrowsWithRetryAfter() async {
        MockURLProtocol.stub(statusURL, status: 503, headers: ["Retry-After": "120"])
        do {
            _ = try await fetch()
            XCTFail("expected an error")
        } catch let error as HTTPError {
            guard case .status(let code, let retryAfter) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code, 503)
            XCTAssertEqual(retryAfter, 120)
            XCTAssertTrue(error.shouldBackOff)
        } catch {
            XCTFail("wrong error type \(error)")
        }
    }

    func testMalformedBodyThrows() async {
        MockURLProtocol.stub(statusURL, body: Data("<html>oops</html>".utf8))
        do {
            _ = try await fetch()
            XCTFail("expected an error")
        } catch {
            // any error is fine, the scheduler maps it to unknown
        }
    }

    func testUserAgentAndNoCookies() async throws {
        MockURLProtocol.stub(statusURL, fixture: "statuspage_status_none.json")
        _ = try await fetch()
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        XCTAssertTrue(agent.hasPrefix("StackStatus/"), "got \(agent)")
        XCTAssertTrue(agent.contains("+https://github.com/richhickson/StackStatus"), "got \(agent)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
}
