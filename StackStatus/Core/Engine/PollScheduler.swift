import Foundation

/// What one poll cycle learned about one vendor.
struct VendorObservation: Hashable, Sendable {
    var vendorID: String
    var state: VendorState
    /// The latest snapshot, or the previous one when the server said 304.
    var snapshot: FeedSnapshot?
    var probes: [ProbeResult]
    /// True when the feed answered 304, so nothing about the vendor changed.
    var unchanged: Bool
    /// Why the feed could not be read, when state is unknown.
    var error: String?
    /// Set while the vendor's status page is being backed off.
    var backedOffUntil: Date?
}

/// The output of one cycle, handed to the state store on the main actor.
struct PollCycleResult: Hashable, Sendable {
    var observations: [VendorObservation]
    var baseline: BaselineResult?
    var startedAt: Date
    var finishedAt: Date
    var timedOut: Bool
}

/// Owns the polling loop. One actor, one loop task, one cycle at a time.
///
/// - Every cycle is a single task group so the radio wakes once.
/// - Per request timeout is 10 seconds (in the URLSession), the whole cycle
///   is capped at 15 seconds; anything still running is cancelled and shown
///   as unknown.
/// - Interval adapts: user setting when green, 2 minutes during an incident,
///   three times the user setting on battery with nothing wrong.
/// - Pause on sleep, poll immediately on wake or on a manual refresh.
/// - 429 and 5xx from a status page back off exponentially, capped at 30
///   minutes, honouring Retry-After.
actor PollScheduler {
    static let cycleTimeout: TimeInterval = 15
    static let maxBackoff: TimeInterval = 30 * 60

    typealias Sink = @Sendable (PollCycleResult) async -> Void

    private let http: HTTPFetching
    private let prober: Prober
    private let baseline: BaselineProbing
    private let adapters: [Platform: any StatusFeedAdapter]
    private let onBattery: @Sendable () -> Bool
    private let sink: Sink
    private let cycleTimeout: TimeInterval

    private var vendors: [Vendor] = []
    private var settings: PollSettings
    private var lastSnapshots: [String: FeedSnapshot] = [:]
    private var backoff: [String: (until: Date, failures: Int)] = [:]
    private var anyIncident = false

    private var loopTask: Task<Void, Never>?
    private var cycleRunning = false
    private var refreshRequested = false
    private var paused = false

    init(
        http: HTTPFetching,
        prober: Prober,
        baseline: BaselineProbing,
        settings: PollSettings,
        adapters: [Platform: any StatusFeedAdapter] = Adapters.all,
        cycleTimeout: TimeInterval = PollScheduler.cycleTimeout,
        onBattery: @escaping @Sendable () -> Bool = { PowerSource.isOnBattery() },
        sink: @escaping Sink
    ) {
        self.http = http
        self.prober = prober
        self.baseline = baseline
        self.settings = settings
        self.adapters = adapters
        self.cycleTimeout = cycleTimeout
        self.onBattery = onBattery
        self.sink = sink
    }

    /// Set the vendor list without starting the loop. Tests drive cycles by hand.
    func setVendorsForTesting(_ vendors: [Vendor]) {
        forgetChanged(vendors)
        self.vendors = vendors
    }

    private func forgetChanged(_ vendors: [Vendor]) {
        let removed = Set(self.vendors.map(\.id)).subtracting(vendors.map(\.id))
        let changed = Set(vendors.filter { new in
            self.vendors.first(where: { $0.id == new.id }).map { $0 != new } ?? true
        }.map(\.id))
        for id in removed.union(changed) {
            lastSnapshots[id] = nil
            backoff[id] = nil
        }
    }

    // MARK: Control

    func start(vendors: [Vendor]) {
        self.vendors = vendors
        paused = false
        restartLoop()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func update(vendors: [Vendor]) {
        forgetChanged(vendors)
        self.vendors = vendors
        refreshNow()
    }

    func update(settings: PollSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        if !cycleRunning { restartLoop(skipImmediatePoll: true) }
    }

    /// Run a cycle as soon as possible without overlapping the current one.
    func refreshNow() {
        guard !paused else { return }
        if cycleRunning {
            refreshRequested = true
        } else {
            restartLoop()
        }
    }

    func systemWillSleep() {
        paused = true
        loopTask?.cancel()
        loopTask = nil
    }

    func systemDidWake() {
        paused = false
        restartLoop()
    }

    var isPaused: Bool { paused }

    // MARK: Loop

    private func restartLoop(skipImmediatePoll: Bool = false) {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.loop(skipFirstPoll: skipImmediatePoll)
        }
    }

    private func loop(skipFirstPoll: Bool) async {
        var skip = skipFirstPoll
        while !Task.isCancelled {
            if !skip {
                await runCycle()
                if refreshRequested {
                    refreshRequested = false
                    continue
                }
            }
            skip = false
            let delay = nextInterval()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    func nextInterval() -> TimeInterval {
        if anyIncident { return min(PollSettings.incidentInterval, settings.userInterval) }
        if onBattery() { return settings.userInterval * PollSettings.batteryMultiplier }
        return settings.userInterval
    }

    // MARK: Cycle

    private enum ChildResult: Sendable {
        case vendor(VendorObservation)
        case baseline(BaselineResult)
        case deadline
    }

    func runCycle() async {
        guard !cycleRunning else { return }
        cycleRunning = true
        defer { cycleRunning = false }

        let startedAt = Date()
        let enabled = vendors.filter(\.enabled)
        var observations: [String: VendorObservation] = [:]
        var baselineResult: BaselineResult?
        var timedOut = false

        // Vendors in backoff are skipped this cycle and keep their last state.
        var toFetch: [Vendor] = []
        for vendor in enabled {
            if let entry = backoff[vendor.id], entry.until > startedAt {
                observations[vendor.id] = VendorObservation(
                    vendorID: vendor.id,
                    state: lastSnapshots[vendor.id]?.state ?? .unknown,
                    snapshot: lastSnapshots[vendor.id],
                    probes: [],
                    unchanged: true,
                    error: "Backing off until \(Formatting.clockTime(entry.until))",
                    backedOffUntil: entry.until
                )
            } else {
                toFetch.append(vendor)
            }
        }

        let http = self.http
        let prober = self.prober
        let baseline = self.baseline
        let adapters = self.adapters
        let settings = self.settings
        let snapshots = self.lastSnapshots
        let deadline = self.cycleTimeout

        await withTaskGroup(of: ChildResult.self) { group in
            for vendor in toFetch {
                group.addTask {
                    let adapter = adapters[vendor.platform] ?? FeedAdapter()
                    return .vendor(await Self.observe(vendor, adapter: adapter, http: http, prober: prober, previous: snapshots[vendor.id]))
                }
            }
            group.addTask {
                .baseline(await baseline.run(internetURL: settings.internetURL, dnsHost: settings.dnsHost))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return .deadline
            }

            var remaining = toFetch.count + 1
            for await result in group {
                switch result {
                case .vendor(let observation):
                    observations[observation.vendorID] = observation
                    remaining -= 1
                case .baseline(let result):
                    baselineResult = result
                    remaining -= 1
                case .deadline:
                    timedOut = remaining > 0
                    remaining = 0
                }
                if remaining == 0 {
                    group.cancelAll()
                    break
                }
            }
        }

        // Anything that did not come back in time is unknown, never an outage.
        for vendor in toFetch where observations[vendor.id] == nil {
            observations[vendor.id] = VendorObservation(
                vendorID: vendor.id, state: .unknown, snapshot: lastSnapshots[vendor.id], probes: [], unchanged: false, error: "Timed out"
            )
        }

        // Remember snapshots and apply backoff decisions.
        for vendor in toFetch {
            guard let observation = observations[vendor.id] else { continue }
            if let snapshot = observation.snapshot, observation.state != .unknown {
                lastSnapshots[vendor.id] = snapshot
            }
            if let until = observation.backedOffUntil {
                let failures = (backoff[vendor.id]?.failures ?? 0) + 1
                let delay = min(until.timeIntervalSince(startedAt), Self.maxBackoff)
                backoff[vendor.id] = (startedAt.addingTimeInterval(Self.backoffDelay(requested: delay, failures: failures, base: settings.userInterval)), failures)
            } else if observation.state != .unknown {
                backoff[vendor.id] = nil
            }
        }

        let ordered = enabled.compactMap { observations[$0.id] }
        anyIncident = ordered.contains { $0.state.isIncident }

        let result = PollCycleResult(
            observations: ordered,
            baseline: baselineResult,
            startedAt: startedAt,
            finishedAt: Date(),
            timedOut: timedOut
        )
        await sink(result)
    }

    /// Retry-After wins when present, otherwise double the user interval per
    /// consecutive failure, capped at 30 minutes.
    static func backoffDelay(requested: TimeInterval?, failures: Int, base: TimeInterval) -> TimeInterval {
        if let requested, requested > 0 { return min(requested, maxBackoff) }
        let exponent = max(0, min(failures, 10))
        return min(base * pow(2, Double(exponent)), maxBackoff)
    }

    /// Fetch one vendor's feed and then its probes, in that order, so the
    /// probes run while the feed's TCP connection is still warm.
    static func observe(_ vendor: Vendor, adapter: any StatusFeedAdapter, http: HTTPFetching, prober: Prober, previous: FeedSnapshot?) async -> VendorObservation {
        var observation = VendorObservation(vendorID: vendor.id, state: .unknown, snapshot: previous, probes: [], unchanged: false, error: nil)
        do {
            switch try await adapter.fetch(vendor, using: http, conditional: previous != nil) {
            case .unchanged:
                if let previous {
                    observation.state = previous.state
                    observation.snapshot = previous
                    observation.unchanged = true
                } else {
                    observation.error = "Not modified with no cached copy"
                }
            case .snapshot(let snapshot):
                observation.state = snapshot.state
                observation.snapshot = snapshot
            }
        } catch let error as HTTPError {
            observation.error = error.description
            if error.shouldBackOff, case .status(_, let retryAfter) = error {
                observation.backedOffUntil = Date().addingTimeInterval(retryAfter ?? 0)
            }
        } catch {
            observation.error = String(describing: error)
        }

        if Task.isCancelled { return observation }

        if !vendor.probes.isEmpty {
            observation.probes = await withTaskGroup(of: (Int, ProbeResult).self) { group in
                for (index, spec) in vendor.probes.enumerated() {
                    group.addTask { (index, await prober.run(spec)) }
                }
                var results: [(Int, ProbeResult)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        return observation
    }
}

/// Battery versus mains, read at the moment the next interval is chosen.
enum PowerSource {
    static func isOnBattery() -> Bool {
        PowerSourceIOKit.isOnBattery()
    }
}
