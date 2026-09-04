import Foundation
import Combine

/// Everything the UI shows, on the main actor. Receives cycle results from
/// the scheduler, runs them through the trackers, and asks the notifier to
/// speak when a transition is confirmed.
@MainActor
final class StateStore: ObservableObject {
    struct VendorEntry: Identifiable {
        let vendor: Vendor
        var observation: VendorObservation?
        var tracker = VendorTracker()
        var verdict: Verdict = .unknown

        var id: String { vendor.id }

        /// The raw latest observation. A timed out poll shows as unknown here
        /// even though the tracker keeps the last confirmed state.
        var displayedState: VendorState { observation?.state ?? .unknown }

        /// When the confirmed state last changed.
        var stateSince: Date? { tracker.confirmedAt }

        var incident: Incident? { observation?.snapshot?.primaryIncident ?? tracker.currentIncident }

        var probeFailing: Bool {
            guard let probes = observation?.probes, !probes.isEmpty else { return false }
            return !probes.allSatisfy(\.ok)
        }

        var errorText: String? { observation?.error }
    }

    @Published private(set) var entries: [VendorEntry]
    @Published private(set) var baseline: BaselineResult?
    @Published private(set) var baselineTracker = BaselineTracker()
    @Published private(set) var lastChecked: Date?
    @Published private(set) var hasPolled = false
    @Published private(set) var lastCycleTimedOut = false
    @Published private(set) var headline = Headline(text: "Checking", tone: .neutral)
    @Published private(set) var isRefreshing = false

    private let notifier: any Notifying

    init(vendors: [Vendor], notifier: any Notifying) {
        self.entries = vendors.map { VendorEntry(vendor: $0) }
        self.notifier = notifier
    }

    var enabledEntries: [VendorEntry] { entries.filter { $0.vendor.enabled } }

    var baselineSignal: BaselineSignal {
        guard let baseline else { return .unknown }
        return baseline.ok ? .ok : .failing
    }

    /// Replace the vendor list, keeping trackers and observations for vendors
    /// whose definition did not change.
    func setVendors(_ vendors: [Vendor]) {
        let existing = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        entries = vendors.map { vendor in
            if let old = existing[vendor.id], old.vendor == vendor { return old }
            return VendorEntry(vendor: vendor)
        }
        recomputeVerdicts()
    }

    func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
    }

    func apply(_ cycle: PollCycleResult) {
        let now = cycle.finishedAt
        var transitions: [(Vendor, VendorTransition)] = []

        for observation in cycle.observations {
            guard let index = entries.firstIndex(where: { $0.id == observation.vendorID }) else { continue }
            entries[index].observation = observation
            let incident = observation.snapshot?.primaryIncident
            if let transition = entries[index].tracker.observe(observation.state, incident: incident, at: now) {
                transitions.append((entries[index].vendor, transition))
            }
        }

        if let result = cycle.baseline {
            baseline = result
            if let event = baselineTracker.observe(ok: result.ok, at: now), event == .wentDown {
                notifier.notifyConnectionDown(since: baselineTracker.downSince ?? now)
            }
        }

        lastChecked = now
        hasPolled = true
        lastCycleTimedOut = cycle.timedOut
        isRefreshing = false
        recomputeVerdicts()

        for (vendor, transition) in transitions {
            notifier.notify(vendor: vendor, transition: transition)
        }
    }

    private func recomputeVerdicts() {
        let signal = baselineSignal
        for index in entries.indices {
            let observation = entries[index].observation
            let feed = VerdictEngine.feedSignal(for: observation?.state ?? .unknown)
            let probe = VerdictEngine.probeSignal(for: observation?.probes ?? [])
            entries[index].verdict = VerdictEngine.verdict(feed: feed, probe: probe, baseline: signal)
        }
        headline = VerdictEngine.headline(
            entries: enabledEntries.map { VerdictEngine.Entry(name: $0.vendor.name, state: $0.displayedState, verdict: $0.verdict) },
            baseline: signal,
            hasPolled: hasPolled
        )
    }
}
