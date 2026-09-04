import Foundation

/// Pure functions that turn feed, probe and baseline signals into verdicts.
/// No state, no side effects, fully covered by table driven tests.
enum VerdictEngine {

    /// The verdict matrix from the brief, with the gaps filled in:
    ///
    /// | Feed        | Probe   | Baseline | Verdict              |
    /// |-------------|---------|----------|----------------------|
    /// | incident    | any     | ok       | vendorIncident       |
    /// | ok          | fail    | ok       | likelyVendorProblem  |
    /// | ok          | fail    | fail     | yourConnection       |
    /// | ok          | ok      | ok       | allGood              |
    /// | unreachable | any     | fail     | yourConnection       |
    ///
    /// Extra rows: a feed that was reached this cycle proves the connection
    /// works, so with baseline failing but feed reachable and probe not
    /// failing, the feed is believed. An unreachable feed with a healthy
    /// baseline and a failing probe points at the vendor; with a passing
    /// probe it is simply unknown. Nothing is decided before the first
    /// baseline result.
    static func verdict(feed: FeedSignal, probe: ProbeSignal, baseline: BaselineSignal) -> Verdict {
        switch (feed, probe, baseline) {
        case (_, _, .unknown):
            return .unknown

        case (.unreachable, _, .failing):
            return .yourConnection
        case (_, .failing, .failing):
            return .yourConnection
        case (.incident, _, .failing):
            return .vendorIncident
        case (.ok, _, .failing):
            return .allGood

        case (.incident, _, .ok):
            return .vendorIncident
        case (.ok, .failing, .ok):
            return .likelyVendorProblem
        case (.ok, _, .ok):
            return .allGood
        case (.unreachable, .failing, .ok):
            return .likelyVendorProblem
        case (.unreachable, _, .ok):
            return .unknown
        }
    }

    /// Reduce a snapshot state to the feed signal.
    static func feedSignal(for state: VendorState) -> FeedSignal {
        switch state {
        case .unknown: return .unreachable
        case .operational: return .ok
        case .degraded, .partialOutage, .majorOutage, .maintenance: return .incident
        }
    }

    /// Reduce a vendor's probe results to one signal. Any failing probe fails
    /// the vendor, since each probe is a separate claim that the service is up.
    static func probeSignal(for results: [ProbeResult]) -> ProbeSignal {
        if results.isEmpty { return .none }
        return results.allSatisfy(\.ok) ? .ok : .failing
    }

    /// One vendor's contribution to the headline.
    struct Entry: Hashable, Sendable {
        var name: String
        var state: VendorState
        var verdict: Verdict
    }

    /// Fold every vendor's verdict into the line at the top of the popover.
    /// The tone drives the icon colour: grey before the first poll and while
    /// the baseline is failing, red for partial or major outages, amber for
    /// degraded, maintenance or a failing probe, green otherwise.
    static func headline(entries: [Entry], baseline: BaselineSignal, hasPolled: Bool) -> Headline {
        guard hasPolled else {
            return Headline(text: "Checking", tone: .neutral)
        }
        if baseline == .failing {
            return Headline(text: "Your connection looks down", tone: .neutral)
        }

        let incidents = entries
            .filter { $0.verdict == .vendorIncident }
            .sorted { $0.state.severity > $1.state.severity }
        if let worst = incidents.first {
            let others = incidents.count - 1
            let text = others == 0
                ? "\(worst.name): \(worst.state.label.lowercased())"
                : "\(worst.name) and \(others) \(others == 1 ? "other" : "others"): \(worst.state.label.lowercased())"
            return Headline(text: text, tone: tone(for: worst.state))
        }

        let suspects = entries.filter { $0.verdict == .likelyVendorProblem }
        if let first = suspects.first {
            let others = suspects.count - 1
            let text = others == 0
                ? "\(first.name): probe failing"
                : "\(first.name) and \(others) \(others == 1 ? "other" : "others"): probe failing"
            return Headline(text: text, tone: .warning)
        }

        if !entries.isEmpty, entries.allSatisfy({ $0.verdict == .unknown }) {
            return Headline(text: "Status pages unreachable", tone: .neutral)
        }

        return Headline(text: "All systems normal", tone: .good)
    }

    static func tone(for state: VendorState) -> Tone {
        switch state {
        case .operational: return .good
        case .degraded, .maintenance: return .warning
        case .partialOutage, .majorOutage: return .bad
        case .unknown: return .neutral
        }
    }
}
