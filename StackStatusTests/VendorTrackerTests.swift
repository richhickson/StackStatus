import XCTest
@testable import StackStatus

final class VendorTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Int) -> Date { t0.addingTimeInterval(TimeInterval(minutes * 60)) }
    private let incident = Incident(id: "abc", title: "API errors", startedAt: Date(timeIntervalSince1970: 1_800_000_000 - 600))

    func testFirstObservationIsAdoptedSilently() {
        var tracker = VendorTracker()
        XCTAssertNil(tracker.observe(.operational, incident: nil, at: at(0)))
        XCTAssertEqual(tracker.confirmed, .operational)
        XCTAssertEqual(tracker.confirmedAt, at(0))
    }

    func testLaunchingDuringIncidentDoesNotNotifyButRemembersStart() {
        var tracker = VendorTracker()
        XCTAssertNil(tracker.observe(.degraded, incident: incident, at: at(0)))
        XCTAssertEqual(tracker.confirmed, .degraded)
        XCTAssertEqual(tracker.incidentSince, incident.startedAt)
    }

    func testSingleBadPollDoesNotTransition() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        XCTAssertNil(tracker.observe(.degraded, incident: incident, at: at(5)))
        XCTAssertEqual(tracker.confirmed, .operational)
        // Back to operational: pending change is discarded, nothing fires.
        XCTAssertNil(tracker.observe(.operational, incident: nil, at: at(10)))
        XCTAssertEqual(tracker.confirmed, .operational)
    }

    func testTwoConsecutiveBadPollsTransition() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        XCTAssertNil(tracker.observe(.degraded, incident: incident, at: at(5)))
        let transition = tracker.observe(.degraded, incident: incident, at: at(10))
        XCTAssertEqual(transition?.kind, .started)
        XCTAssertEqual(transition?.from, .operational)
        XCTAssertEqual(transition?.to, .degraded)
        XCTAssertEqual(transition?.incident, incident)
        XCTAssertEqual(tracker.confirmed, .degraded)
        XCTAssertTrue(tracker.inIncident)
    }

    func testMajorOutageIsImmediate() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        let transition = tracker.observe(.majorOutage, incident: incident, at: at(5))
        XCTAssertEqual(transition?.kind, .started)
        XCTAssertEqual(transition?.to, .majorOutage)
    }

    func testAlternatingStatesNeverConfirm() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        XCTAssertNil(tracker.observe(.degraded, incident: nil, at: at(5)))
        XCTAssertNil(tracker.observe(.partialOutage, incident: nil, at: at(10)))
        XCTAssertNil(tracker.observe(.degraded, incident: nil, at: at(15)))
        XCTAssertEqual(tracker.confirmed, .operational)
    }

    func testResolvedRequiresTwoPollsAndReportsDuration() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        _ = tracker.observe(.degraded, incident: incident, at: at(5))
        _ = tracker.observe(.degraded, incident: incident, at: at(10))
        XCTAssertNil(tracker.observe(.operational, incident: nil, at: at(40)))
        let transition = tracker.observe(.operational, incident: nil, at: at(45))
        XCTAssertEqual(transition?.kind, .resolved)
        XCTAssertEqual(transition?.from, .degraded)
        XCTAssertEqual(transition?.to, .operational)
        // Duration runs from the vendor's own start time (10 minutes before t0) to confirmation at +45.
        XCTAssertEqual(transition?.duration, 55 * 60)
        XCTAssertEqual(transition?.incident, incident, "resolved transition carries the incident that ended")
        XCTAssertFalse(tracker.inIncident)
        XCTAssertNil(tracker.incidentSince)
    }

    func testDurationFallsBackToConfirmationTimeWithoutIncidentStart() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        _ = tracker.observe(.degraded, incident: nil, at: at(5))
        _ = tracker.observe(.degraded, incident: nil, at: at(10))
        _ = tracker.observe(.operational, incident: nil, at: at(20))
        let transition = tracker.observe(.operational, incident: nil, at: at(25))
        XCTAssertEqual(transition?.duration, 15 * 60)
    }

    func testUnknownIsTransparent() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        _ = tracker.observe(.degraded, incident: incident, at: at(5))
        // A timeout in the middle must not reset the pending count or confirm anything.
        XCTAssertNil(tracker.observe(.unknown, incident: nil, at: at(10)))
        XCTAssertEqual(tracker.confirmed, .operational)
        let transition = tracker.observe(.degraded, incident: incident, at: at(15))
        XCTAssertEqual(transition?.kind, .started)
    }

    func testUnknownDuringIncidentDoesNotResolve() {
        var tracker = VendorTracker()
        _ = tracker.observe(.majorOutage, incident: incident, at: at(0))
        XCTAssertNil(tracker.observe(.unknown, incident: nil, at: at(5)))
        XCTAssertNil(tracker.observe(.unknown, incident: nil, at: at(10)))
        XCTAssertEqual(tracker.confirmed, .majorOutage)
        XCTAssertTrue(tracker.inIncident)
    }

    func testEscalationIsAChangedTransitionThatWorsened() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        _ = tracker.observe(.degraded, incident: incident, at: at(5))
        _ = tracker.observe(.degraded, incident: incident, at: at(10))
        _ = tracker.observe(.partialOutage, incident: incident, at: at(15))
        let transition = tracker.observe(.partialOutage, incident: incident, at: at(20))
        XCTAssertEqual(transition?.kind, .changed)
        XCTAssertEqual(transition?.worsened, true)
        XCTAssertEqual(tracker.incidentSince, incident.startedAt, "escalation keeps the original start time")
    }

    func testDeescalationIsAChangedTransitionThatDidNotWorsen() {
        var tracker = VendorTracker()
        _ = tracker.observe(.majorOutage, incident: incident, at: at(0))
        _ = tracker.observe(.degraded, incident: incident, at: at(5))
        let transition = tracker.observe(.degraded, incident: incident, at: at(10))
        XCTAssertEqual(transition?.kind, .changed)
        XCTAssertEqual(transition?.worsened, false)
    }

    func testMaintenanceCountsAsIncidentForTransitions() {
        var tracker = VendorTracker()
        _ = tracker.observe(.operational, incident: nil, at: at(0))
        _ = tracker.observe(.maintenance, incident: nil, at: at(5))
        XCTAssertEqual(tracker.observe(.maintenance, incident: nil, at: at(10))?.kind, .started)
        _ = tracker.observe(.operational, incident: nil, at: at(15))
        XCTAssertEqual(tracker.observe(.operational, incident: nil, at: at(20))?.kind, .resolved)
    }

    // MARK: Baseline

    func testBaselineSingleFailureIsIgnored() {
        var b = BaselineTracker()
        XCTAssertNil(b.observe(ok: true, at: at(0)))
        XCTAssertNil(b.observe(ok: false, at: at(5)))
        XCTAssertFalse(b.isDown)
        XCTAssertNil(b.observe(ok: true, at: at(10)))
        XCTAssertEqual(b.consecutiveFailures, 0)
    }

    func testBaselineTwoFailuresNotifyOnce() {
        var b = BaselineTracker()
        XCTAssertNil(b.observe(ok: false, at: at(0)))
        XCTAssertEqual(b.observe(ok: false, at: at(5)), .wentDown)
        XCTAssertTrue(b.isDown)
        XCTAssertEqual(b.downSince, at(5))
        XCTAssertNil(b.observe(ok: false, at: at(10)), "no repeat notification while still down")
        XCTAssertEqual(b.observe(ok: true, at: at(15)), .restored)
        XCTAssertFalse(b.isDown)
    }
}
