import XCTest
@testable import StackStatus

final class VerdictEngineTests: XCTestCase {

    // Every row of the matrix in the brief, plus the filled in gaps.
    func testVerdictMatrix() {
        struct Row {
            let feed: FeedSignal
            let probe: ProbeSignal
            let baseline: BaselineSignal
            let expected: Verdict
            let line: UInt
            init(_ feed: FeedSignal, _ probe: ProbeSignal, _ baseline: BaselineSignal, _ expected: Verdict, line: UInt = #line) {
                self.feed = feed; self.probe = probe; self.baseline = baseline; self.expected = expected; self.line = line
            }
        }

        let rows: [Row] = [
            // Brief row 1: incident | any | ok -> vendor incident
            Row(.incident, .ok, .ok, .vendorIncident),
            Row(.incident, .failing, .ok, .vendorIncident),
            Row(.incident, .none, .ok, .vendorIncident),
            // Brief row 2: ok | fail | ok -> looks like a vendor problem
            Row(.ok, .failing, .ok, .likelyVendorProblem),
            // Brief row 3: ok | fail | fail -> your connection
            Row(.ok, .failing, .failing, .yourConnection),
            // Brief row 4: ok | ok | ok -> all good
            Row(.ok, .ok, .ok, .allGood),
            Row(.ok, .none, .ok, .allGood),
            // Brief row 5: unreachable | any | fail -> your connection
            Row(.unreachable, .ok, .failing, .yourConnection),
            Row(.unreachable, .failing, .failing, .yourConnection),
            Row(.unreachable, .none, .failing, .yourConnection),
            // Gaps: baseline failing but the feed was reached this cycle.
            Row(.incident, .ok, .failing, .vendorIncident),
            Row(.incident, .none, .failing, .vendorIncident),
            Row(.incident, .failing, .failing, .yourConnection),
            Row(.ok, .ok, .failing, .allGood),
            Row(.ok, .none, .failing, .allGood),
            // Gaps: feed unreachable while our connection is fine.
            Row(.unreachable, .failing, .ok, .likelyVendorProblem),
            Row(.unreachable, .ok, .ok, .unknown),
            Row(.unreachable, .none, .ok, .unknown),
            // Nothing decided before the first baseline result.
            Row(.ok, .ok, .unknown, .unknown),
            Row(.incident, .ok, .unknown, .unknown),
            Row(.unreachable, .failing, .unknown, .unknown),
        ]

        for row in rows {
            let got = VerdictEngine.verdict(feed: row.feed, probe: row.probe, baseline: row.baseline)
            XCTAssertEqual(got, row.expected, "feed=\(row.feed) probe=\(row.probe) baseline=\(row.baseline)", line: row.line)
        }
    }

    func testMatrixIsTotal() {
        // Every combination must produce a verdict without crashing.
        let feeds: [FeedSignal] = [.ok, .incident, .unreachable]
        let probes: [ProbeSignal] = [.ok, .failing, .none]
        let baselines: [BaselineSignal] = [.ok, .failing, .unknown]
        var count = 0
        for f in feeds { for p in probes { for b in baselines {
            _ = VerdictEngine.verdict(feed: f, probe: p, baseline: b)
            count += 1
        } } }
        XCTAssertEqual(count, 27)
    }

    func testFeedSignalMapping() {
        XCTAssertEqual(VerdictEngine.feedSignal(for: .operational), .ok)
        XCTAssertEqual(VerdictEngine.feedSignal(for: .degraded), .incident)
        XCTAssertEqual(VerdictEngine.feedSignal(for: .partialOutage), .incident)
        XCTAssertEqual(VerdictEngine.feedSignal(for: .majorOutage), .incident)
        XCTAssertEqual(VerdictEngine.feedSignal(for: .maintenance), .incident)
        XCTAssertEqual(VerdictEngine.feedSignal(for: .unknown), .unreachable)
    }

    func testProbeSignalMapping() {
        let spec = ProbeSpec.tcp(host: "example.com", port: 443)
        XCTAssertEqual(VerdictEngine.probeSignal(for: []), .none)
        XCTAssertEqual(VerdictEngine.probeSignal(for: [ProbeResult(spec: spec, ok: true)]), .ok)
        XCTAssertEqual(VerdictEngine.probeSignal(for: [ProbeResult(spec: spec, ok: true), ProbeResult(spec: spec, ok: false)]), .failing)
    }

    func testWorstState() {
        XCTAssertEqual(VendorState.worst(of: [.operational, .maintenance, .degraded]), .degraded)
        XCTAssertEqual(VendorState.worst(of: [.operational, .maintenance]), .maintenance)
        XCTAssertEqual(VendorState.worst(of: [.majorOutage, .partialOutage]), .majorOutage)
        XCTAssertEqual(VendorState.worst(of: [.unknown, .operational]), .operational)
        XCTAssertEqual(VendorState.worst(of: []), .unknown)
    }

    // MARK: Headline

    private func entry(_ name: String, _ state: VendorState, _ verdict: Verdict) -> VerdictEngine.Entry {
        VerdictEngine.Entry(name: name, state: state, verdict: verdict)
    }

    func testHeadlineBeforeFirstPoll() {
        let h = VerdictEngine.headline(entries: [], baseline: .unknown, hasPolled: false)
        XCTAssertEqual(h.tone, .neutral)
    }

    func testHeadlineAllGood() {
        let h = VerdictEngine.headline(
            entries: [entry("GitHub", .operational, .allGood), entry("Cloudflare", .operational, .allGood)],
            baseline: .ok, hasPolled: true)
        XCTAssertEqual(h, Headline(text: "All systems normal", tone: .good))
    }

    func testHeadlineYourConnectionWinsAndIsGrey() {
        let h = VerdictEngine.headline(
            entries: [entry("GitHub", .majorOutage, .yourConnection)],
            baseline: .failing, hasPolled: true)
        XCTAssertEqual(h, Headline(text: "Your connection looks down", tone: .neutral))
    }

    func testHeadlineSingleIncidentNamesVendorAndState() {
        let h = VerdictEngine.headline(
            entries: [entry("GitHub", .operational, .allGood), entry("Cloudflare", .partialOutage, .vendorIncident)],
            baseline: .ok, hasPolled: true)
        XCTAssertEqual(h, Headline(text: "Cloudflare: partial outage", tone: .bad))
    }

    func testHeadlineMultipleIncidentsPicksWorst() {
        let h = VerdictEngine.headline(
            entries: [entry("GitHub", .degraded, .vendorIncident), entry("Cloudflare", .majorOutage, .vendorIncident)],
            baseline: .ok, hasPolled: true)
        XCTAssertEqual(h, Headline(text: "Cloudflare and 1 other: major outage", tone: .bad))
    }

    func testHeadlineDegradedIsAmber() {
        let h = VerdictEngine.headline(
            entries: [entry("OpenAI", .degraded, .vendorIncident)],
            baseline: .ok, hasPolled: true)
        XCTAssertEqual(h.tone, .warning)
        XCTAssertEqual(h.text, "OpenAI: degraded")
    }

    func testHeadlineProbeFailing() {
        let h = VerdictEngine.headline(
            entries: [entry("OpenAI", .operational, .likelyVendorProblem), entry("GitHub", .operational, .allGood)],
            baseline: .ok, hasPolled: true)
        XCTAssertEqual(h, Headline(text: "OpenAI: probe failing", tone: .warning))
    }

    func testHeadlineAllUnknown() {
        let h = VerdictEngine.headline(
            entries: [entry("OpenAI", .unknown, .unknown), entry("GitHub", .unknown, .unknown)],
            baseline: .ok, hasPolled: true)
        XCTAssertEqual(h.tone, .neutral)
    }

    func testHeadlineSomeUnknownIsStillGood() {
        let h = VerdictEngine.headline(
            entries: [entry("OpenAI", .unknown, .unknown), entry("GitHub", .operational, .allGood)],
            baseline: .ok, hasPolled: true)
        XCTAssertEqual(h.tone, .good)
    }
}
