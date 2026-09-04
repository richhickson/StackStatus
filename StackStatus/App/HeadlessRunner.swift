import Foundation

/// `StackStatus.app/Contents/MacOS/StackStatus --once` runs one poll cycle
/// against the user's vendor list, prints the result, and exits. Used to
/// verify live states from a terminal and by Scripts/measure.sh. No menubar
/// item, no notifications.
enum HeadlessRunner {
    @MainActor
    static func runOnce() async -> Int32 {
        let settings = AppSettings()
        let config: VendorConfig
        do {
            config = try ConfigStore().load()
        } catch {
            fputs("Could not load vendors.json: \(error)\n", stderr)
            return 2
        }

        let http = HTTPClient()
        let store = StateStore(vendors: config.vendors, notifier: SilentNotifier())
        let scheduler = PollScheduler(
            http: http,
            prober: ProbeRunner(http: http),
            baseline: BaselineProber(http: http),
            settings: settings.pollSettings,
            sink: { result in await MainActor.run { store.apply(result) } }
        )
        await scheduler.setVendorsForTesting(config.vendors)
        let started = Date()
        await scheduler.runCycle()
        let elapsed = Date().timeIntervalSince(started)

        print("StackStatus \(HTTPClient.version), one cycle in \(Formatting.latency(elapsed))\(store.lastCycleTimedOut ? " (timed out)" : "")")
        if let baseline = store.baseline {
            print("baseline  " + [("gateway", baseline.gateway), ("dns", baseline.dns), ("internet", baseline.internet)].map { label, result in
                guard let result else { return "\(label): not run" }
                return "\(label): \(result.ok ? "ok" : "FAIL") \(Formatting.latency(result.latency))\(result.ok ? "" : " (\(result.detail ?? ""))")"
            }.joined(separator: " | "))
        }
        for entry in store.enabledEntries {
            let probes = entry.observation?.probes.map { "\($0.ok ? "ok" : "FAIL") \(Formatting.latency($0.latency))" }.joined(separator: ", ") ?? ""
            var line = "\(entry.vendor.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(entry.displayedState.label.padding(toLength: 15, withPad: " ", startingAt: 0)) verdict: \(entry.verdict)"
            if !probes.isEmpty { line += "  probes: \(probes)" }
            if let incident = entry.incident, entry.displayedState.isIncident { line += "  incident: \(incident.title)" }
            if let error = entry.errorText { line += "  error: \(error)" }
            print(line)
        }
        print("headline  \(store.headline.text) [\(store.headline.tone)]")
        return 0
    }
}

@MainActor
final class SilentNotifier: Notifying {
    func notify(vendor: Vendor, transition: VendorTransition) {}
    func notifyConnectionDown(since: Date) {}
}
