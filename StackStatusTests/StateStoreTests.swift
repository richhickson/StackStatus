import XCTest
@testable import StackStatus

@MainActor
final class RecordingNotifier: Notifying {
    var vendorNotifications: [(Vendor, VendorTransition)] = []
    var connectionDown: [Date] = []

    func notify(vendor: Vendor, transition: VendorTransition) {
        vendorNotifications.append((vendor, transition))
    }

    func notifyConnectionDown(since: Date) {
        connectionDown.append(since)
    }
}

@MainActor
final class StateStoreTests: XCTestCase {
    private let cloudflare = makeVendor("cloudflare", platform: .statuspage, base: "https://status.cf.test")
    private let github = makeVendor("github", platform: .statuspage, base: "https://status.gh.test")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func cycle(
        _ states: [String: VendorState],
        incidents: [String: Incident] = [:],
        probesOK: [String: Bool] = [:],
        baselineOK: Bool? = true,
        minute: Int,
        timedOut: Bool = false
    ) -> PollCycleResult {
        let at = t0.addingTimeInterval(TimeInterval(minute * 60))
        let observations = states.keys.sorted().map { id -> VendorObservation in
            let state = states[id]!
            let snapshot = state == .unknown ? nil : FeedSnapshot(state: state, incidents: incidents[id].map { [$0] } ?? [], fetchedAt: at)
            var probes: [ProbeResult] = []
            if let ok = probesOK[id] {
                probes = [ProbeResult(spec: .tcp(host: id, port: 443), ok: ok, latency: 0.01, checkedAt: at)]
            }
            return VendorObservation(vendorID: id, state: state, snapshot: snapshot, probes: probes, unchanged: false, error: state == .unknown ? "Timed out" : nil)
        }
        let baseline = baselineOK.map { ok -> BaselineResult in
            let r = ProbeResult(spec: .httpsHead(url: URL(string: "https://ok.test")!), ok: ok, latency: 0.02, checkedAt: at)
            return BaselineResult(gateway: r, dns: r, internet: r, checkedAt: at)
        }
        return PollCycleResult(observations: observations, baseline: baseline, startedAt: at, finishedAt: at, timedOut: timedOut)
    }

    func testInitialStateBeforeAnyPoll() {
        let store = StateStore(vendors: [cloudflare, github], notifier: RecordingNotifier())
        XCTAssertFalse(store.hasPolled)
        XCTAssertEqual(store.headline.tone, .neutral)
        XCTAssertEqual(store.entries.map(\.id), ["cloudflare", "github"])
        XCTAssertEqual(store.entries[0].displayedState, .unknown)
    }

    func testAllGoodAfterFirstPoll() {
        let store = StateStore(vendors: [cloudflare, github], notifier: RecordingNotifier())
        store.apply(cycle(["cloudflare": .operational, "github": .operational], minute: 0))
        XCTAssertTrue(store.hasPolled)
        XCTAssertEqual(store.headline, Headline(text: "All systems normal", tone: .good))
        XCTAssertEqual(store.entries[0].verdict, .allGood)
        XCTAssertEqual(store.lastChecked, t0)
    }

    func testIncidentNotifiesExactlyOnceOnStartAndOnceOnResolution() {
        let notifier = RecordingNotifier()
        let store = StateStore(vendors: [cloudflare], notifier: notifier)
        let incident = Incident(id: "i1", title: "API errors", url: URL(string: "https://status.cf.test/incidents/i1"), startedAt: t0.addingTimeInterval(-300))

        store.apply(cycle(["cloudflare": .operational], minute: 0))
        store.apply(cycle(["cloudflare": .partialOutage], incidents: ["cloudflare": incident], minute: 5))
        XCTAssertEqual(notifier.vendorNotifications.count, 0, "one bad poll must not notify")
        XCTAssertEqual(store.headline.text, "Cloudflare: partial outage", "but the UI shows it straight away")
        XCTAssertEqual(store.headline.tone, .bad)

        store.apply(cycle(["cloudflare": .partialOutage], incidents: ["cloudflare": incident], minute: 10))
        XCTAssertEqual(notifier.vendorNotifications.count, 1)
        XCTAssertEqual(notifier.vendorNotifications[0].1.kind, .started)
        XCTAssertEqual(notifier.vendorNotifications[0].1.incident?.title, "API errors")

        // Several more polls in the same state: silence.
        store.apply(cycle(["cloudflare": .partialOutage], incidents: ["cloudflare": incident], minute: 15))
        store.apply(cycle(["cloudflare": .partialOutage], incidents: ["cloudflare": incident], minute: 20))
        XCTAssertEqual(notifier.vendorNotifications.count, 1)

        store.apply(cycle(["cloudflare": .operational], minute: 25))
        store.apply(cycle(["cloudflare": .operational], minute: 30))
        XCTAssertEqual(notifier.vendorNotifications.count, 2)
        XCTAssertEqual(notifier.vendorNotifications[1].1.kind, .resolved)
        XCTAssertEqual(notifier.vendorNotifications[1].1.duration, 35 * 60)
        XCTAssertEqual(store.headline.tone, .good)
    }

    func testMajorOutageNotifiesImmediately() {
        let notifier = RecordingNotifier()
        let store = StateStore(vendors: [github], notifier: notifier)
        store.apply(cycle(["github": .operational], minute: 0))
        store.apply(cycle(["github": .majorOutage], minute: 5))
        XCTAssertEqual(notifier.vendorNotifications.count, 1)
        XCTAssertEqual(notifier.vendorNotifications[0].1.to, .majorOutage)
    }

    func testTimedOutVendorShowsUnknownNotOutage() {
        let notifier = RecordingNotifier()
        let store = StateStore(vendors: [github], notifier: notifier)
        store.apply(cycle(["github": .operational], minute: 0))
        store.apply(cycle(["github": .unknown], minute: 5, timedOut: true))
        XCTAssertEqual(store.entries[0].displayedState, .unknown)
        XCTAssertEqual(store.entries[0].verdict, .unknown)
        XCTAssertEqual(store.entries[0].tracker.confirmed, .operational)
        XCTAssertTrue(store.lastCycleTimedOut)
        XCTAssertEqual(store.headline.tone, .neutral)
        XCTAssertTrue(notifier.vendorNotifications.isEmpty)
    }

    func testConnectionDownNotifiesOnceAfterTwoFailedPollsAndGreysTheIcon() {
        let notifier = RecordingNotifier()
        let store = StateStore(vendors: [github], notifier: notifier)
        store.apply(cycle(["github": .operational], probesOK: ["github": true], baselineOK: true, minute: 0))
        // Cable pulled: feed unreachable, probe failing, baseline failing.
        store.apply(cycle(["github": .unknown], probesOK: ["github": false], baselineOK: false, minute: 5))
        XCTAssertTrue(notifier.connectionDown.isEmpty, "single failed baseline poll never notifies")
        XCTAssertEqual(store.headline, Headline(text: "Your connection looks down", tone: .neutral))
        XCTAssertEqual(store.entries[0].verdict, .yourConnection)
        XCTAssertNotEqual(store.entries[0].displayedState, .majorOutage, "no vendor is shown as down")

        store.apply(cycle(["github": .unknown], probesOK: ["github": false], baselineOK: false, minute: 10))
        XCTAssertEqual(notifier.connectionDown.count, 1)
        store.apply(cycle(["github": .unknown], probesOK: ["github": false], baselineOK: false, minute: 15))
        XCTAssertEqual(notifier.connectionDown.count, 1, "no repeat while still down")
        XCTAssertTrue(notifier.vendorNotifications.isEmpty, "no vendor notification while it is our connection")

        store.apply(cycle(["github": .operational], probesOK: ["github": true], baselineOK: true, minute: 20))
        XCTAssertEqual(store.headline.tone, .good)
        XCTAssertFalse(store.baselineTracker.isDown)
    }

    func testProbeFailingWithFeedOKIsLikelyVendorProblem() {
        let store = StateStore(vendors: [github], notifier: RecordingNotifier())
        store.apply(cycle(["github": .operational], probesOK: ["github": false], baselineOK: true, minute: 0))
        XCTAssertEqual(store.entries[0].verdict, .likelyVendorProblem)
        XCTAssertTrue(store.entries[0].probeFailing)
        XCTAssertEqual(store.headline, Headline(text: "Github: probe failing", tone: .warning))
    }

    func testMissingBaselineKeepsPreviousBaseline() {
        let store = StateStore(vendors: [github], notifier: RecordingNotifier())
        store.apply(cycle(["github": .operational], baselineOK: true, minute: 0))
        store.apply(cycle(["github": .operational], baselineOK: nil, minute: 5))
        XCTAssertEqual(store.baselineSignal, .ok)
        XCTAssertEqual(store.headline.tone, .good)
    }

    func testDisabledVendorIsIgnoredInHeadline() {
        var disabled = cloudflare
        disabled.enabled = false
        let store = StateStore(vendors: [disabled, github], notifier: RecordingNotifier())
        store.apply(cycle(["github": .operational], minute: 0))
        XCTAssertEqual(store.headline.tone, .good)
        XCTAssertEqual(store.enabledEntries.map(\.id), ["github"])
    }

    func testSetVendorsKeepsTrackersForUnchangedVendors() {
        let store = StateStore(vendors: [cloudflare, github], notifier: RecordingNotifier())
        store.apply(cycle(["cloudflare": .degraded, "github": .operational], minute: 0))
        var renamed = github
        renamed.name = "GitHub Enterprise"
        store.setVendors([renamed, cloudflare])
        XCTAssertEqual(store.entries.map(\.id), ["github", "cloudflare"])
        XCTAssertEqual(store.entries[1].tracker.confirmed, .degraded, "unchanged vendor keeps its tracker")
        XCTAssertEqual(store.entries[0].tracker.confirmed, .unknown, "edited vendor starts fresh")
    }
}
