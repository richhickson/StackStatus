import XCTest
@testable import StackStatus

/// Probe results are decided by the test, keyed on the probe label.
struct FakeProber: Prober {
    var failing: Set<String> = []
    func run(_ spec: ProbeSpec) async -> ProbeResult {
        ProbeResult(spec: spec, ok: !failing.contains(spec.label), latency: 0.01, detail: "fake")
    }
}

struct FakeBaseline: BaselineProbing {
    var ok = true
    func run(internetURL: URL, dnsHost: String) async -> BaselineResult {
        let spec = ProbeSpec.httpsHead(url: internetURL)
        let result = ProbeResult(spec: spec, ok: ok, latency: 0.02)
        return BaselineResult(gateway: result, dns: result, internet: result, checkedAt: Date())
    }
}

/// Collects cycle results from the scheduler's sink.
actor CycleCollector {
    private(set) var cycles: [PollCycleResult] = []
    func add(_ cycle: PollCycleResult) { cycles.append(cycle) }
}

final class PollSchedulerTests: XCTestCase {
    private let github = makeVendor("github", platform: .statuspage, base: "https://status.github.test",
                                    probes: [.httpsHead(url: URL(string: "https://api.github.test/")!)])
    private let openai = makeVendor("openai", platform: .incidentio, base: "https://status.openai.test")
    private var collector = CycleCollector()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        collector = CycleCollector()
    }

    private func makeScheduler(
        prober: FakeProber = FakeProber(),
        baseline: FakeBaseline = FakeBaseline(),
        onBattery: Bool = false,
        cycleTimeout: TimeInterval = 15,
        interval: TimeInterval = 300
    ) -> PollScheduler {
        let collector = self.collector
        return PollScheduler(
            http: makeMockClient(),
            prober: prober,
            baseline: baseline,
            settings: PollSettings(userInterval: interval, internetURL: URL(string: "https://example.test/ok")!, dnsHost: "example.test"),
            cycleTimeout: cycleTimeout,
            onBattery: { onBattery },
            sink: { await collector.add($0) }
        )
    }

    private func latest() async throws -> PollCycleResult {
        let cycles = await collector.cycles
        return try XCTUnwrap(cycles.last)
    }

    private func stubQuiet() {
        MockURLProtocol.stub("https://status.github.test/api/v2/status.json", headers: ["ETag": "W/\"g1\""], fixture: "statuspage_status_none.json")
        MockURLProtocol.stub("https://status.openai.test/api/v1/summary", fixture: "incidentio_v1_summary_none.json")
    }

    func testCycleObservesEveryEnabledVendorAndBaseline() async throws {
        stubQuiet()
        let scheduler = makeScheduler()
        await scheduler.setVendorsForTesting([github, openai])
        await scheduler.runCycle()

        let cycle = try await latest()
        XCTAssertEqual(cycle.observations.map(\.vendorID), ["github", "openai"])
        XCTAssertEqual(cycle.observations.map(\.state), [.operational, .operational])
        XCTAssertEqual(cycle.observations[0].probes.count, 1)
        XCTAssertEqual(cycle.observations[0].probes[0].ok, true)
        XCTAssertEqual(cycle.baseline?.ok, true)
        XCTAssertFalse(cycle.timedOut)
        // One feed request per vendor; probes go through the fake prober.
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testDisabledVendorIsSkipped() async throws {
        stubQuiet()
        var disabled = openai
        disabled.enabled = false
        let scheduler = makeScheduler()
        await scheduler.setVendorsForTesting([github, disabled])
        await scheduler.runCycle()
        let cycle = try await latest()
        XCTAssertEqual(cycle.observations.map(\.vendorID), ["github"])
        XCTAssertTrue(MockURLProtocol.requests(for: "https://status.openai.test/api/v1/summary").isEmpty)
    }

    func testSecondCycleIsConditionalAnd304KeepsState() async throws {
        MockURLProtocol.stub("https://status.github.test/api/v2/status.json", headers: ["ETag": "W/\"g1\""], fixture: "statuspage_status_minor.json")
        MockURLProtocol.stub("https://status.github.test/api/v2/incidents/unresolved.json", fixture: "statuspage_unresolved_minor.json")
        let scheduler = makeScheduler()
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()

        MockURLProtocol.stub("https://status.github.test/api/v2/status.json", status: 304, headers: ["ETag": "W/\"g1\""])
        await scheduler.runCycle()

        let cycles = await collector.cycles
        XCTAssertEqual(cycles.count, 2)
        let second = try XCTUnwrap(cycles.last?.observations.first)
        XCTAssertTrue(second.unchanged)
        XCTAssertEqual(second.state, .degraded)
        XCTAssertEqual(second.snapshot?.primaryIncident?.title, "Incorrect geo location for some Cloudflare WARP users")
        let statusRequests = MockURLProtocol.requests(for: "https://status.github.test/api/v2/status.json")
        XCTAssertEqual(statusRequests.count, 2)
        XCTAssertNil(statusRequests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(statusRequests[1].value(forHTTPHeaderField: "If-None-Match"), "W/\"g1\"")
    }

    func testServerErrorIsUnknownAndBacksOff() async throws {
        MockURLProtocol.stub("https://status.github.test/api/v2/status.json", status: 503, headers: ["Retry-After": "600"])
        let scheduler = makeScheduler()
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()

        let first = try await latest().observations[0]
        XCTAssertEqual(first.state, .unknown)
        XCTAssertEqual(first.error, "HTTP 503")
        XCTAssertNotNil(first.backedOffUntil)

        // Next cycle: the vendor is skipped, keeps unknown, and no request goes out.
        await scheduler.runCycle()
        let second = try await latest().observations[0]
        XCTAssertEqual(second.state, .unknown)
        XCTAssertTrue(second.unchanged)
        XCTAssertNotNil(second.backedOffUntil)
        XCTAssertEqual(MockURLProtocol.requests(for: "https://status.github.test/api/v2/status.json").count, 1)
    }

    func testTransportErrorIsUnknownWithoutBackoff() async throws {
        // No stub at all: the mock fails with cannotConnectToHost.
        let scheduler = makeScheduler()
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()
        let first = try await latest().observations[0]
        XCTAssertEqual(first.state, .unknown)
        XCTAssertNil(first.backedOffUntil)
        XCTAssertNotNil(first.error)
        // The vendor probe still ran even though the feed failed.
        XCTAssertEqual(first.probes.count, 1)
    }

    func testCycleDeadlineMarksSlowVendorUnknown() async throws {
        MockURLProtocol.stub("https://status.openai.test/api/v1/summary", fixture: "incidentio_v1_summary_none.json")
        MockURLProtocol.stub("https://status.github.test/api/v2/status.json", fixture: "statuspage_status_none.json", delay: 3)
        let scheduler = makeScheduler(cycleTimeout: 0.5)
        await scheduler.setVendorsForTesting([github, openai])
        let started = Date()
        await scheduler.runCycle()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "the deadline must cut the cycle short")

        let cycle = try await latest()
        XCTAssertTrue(cycle.timedOut)
        let slow = try XCTUnwrap(cycle.observations.first(where: { $0.vendorID == "github" }))
        XCTAssertEqual(slow.state, .unknown)
        XCTAssertNil(slow.backedOffUntil, "a timeout never triggers backoff")
        let fast = try XCTUnwrap(cycle.observations.first(where: { $0.vendorID == "openai" }))
        XCTAssertEqual(fast.state, .operational)
    }

    func testFailingProbeIsReported() async throws {
        stubQuiet()
        let scheduler = makeScheduler(prober: FakeProber(failing: ["HEAD api.github.test"]))
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()
        let observation = try await latest().observations[0]
        XCTAssertEqual(observation.state, .operational)
        XCTAssertEqual(observation.probes.first?.ok, false)
    }

    // MARK: Interval

    func testIntervalIsUserSettingWhenGreen() async {
        stubQuiet()
        let scheduler = makeScheduler(interval: 300)
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()
        let interval = await scheduler.nextInterval()
        XCTAssertEqual(interval, 300)
    }

    func testIntervalDropsToTwoMinutesDuringIncident() async {
        MockURLProtocol.stub("https://status.github.test/api/v2/status.json", fixture: "statuspage_status_major.json")
        MockURLProtocol.stub("https://status.github.test/api/v2/incidents/unresolved.json", fixture: "statuspage_unresolved_major.json")
        let scheduler = makeScheduler(onBattery: true, interval: 300)
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()
        let interval = await scheduler.nextInterval()
        XCTAssertEqual(interval, 120, "incident beats battery")
    }

    func testIntervalTriplesOnBattery() async {
        stubQuiet()
        let scheduler = makeScheduler(onBattery: true, interval: 300)
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()
        let interval = await scheduler.nextInterval()
        XCTAssertEqual(interval, 900)
    }

    func testBackoffDelay() {
        XCTAssertEqual(PollScheduler.backoffDelay(requested: 90, failures: 1, base: 300), 90, "Retry-After wins")
        XCTAssertEqual(PollScheduler.backoffDelay(requested: nil, failures: 1, base: 300), 600)
        XCTAssertEqual(PollScheduler.backoffDelay(requested: nil, failures: 2, base: 300), 1200)
        XCTAssertEqual(PollScheduler.backoffDelay(requested: nil, failures: 6, base: 300), 1800, "capped at 30 minutes")
        XCTAssertEqual(PollScheduler.backoffDelay(requested: 7200, failures: 1, base: 300), 1800, "Retry-After is capped too")
    }

    func testUpdatingAVendorForgetsItsCachedSnapshot() async throws {
        MockURLProtocol.stub("https://status.github.test/api/v2/status.json", headers: ["ETag": "W/\"g1\""], fixture: "statuspage_status_none.json")
        let scheduler = makeScheduler()
        await scheduler.setVendorsForTesting([github])
        await scheduler.runCycle()

        var edited = github
        edited.name = "GitHub (edited)"
        await scheduler.setVendorsForTesting([edited])
        await scheduler.runCycle()
        let requests = MockURLProtocol.requests(for: "https://status.github.test/api/v2/status.json")
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-None-Match"), "edited vendor is fetched fresh")
    }
}
