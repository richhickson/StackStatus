import Foundation

/// A confirmed change in a vendor's state, produced by `VendorTracker`.
struct VendorTransition: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Operational to any incident state.
        case started
        /// Incident state to operational.
        case resolved
        /// One incident state to another, for example degraded to major outage.
        case changed
    }

    var kind: Kind
    var from: VendorState
    var to: VendorState
    var incident: Incident?
    /// For `resolved`: how long the incident lasted.
    var duration: TimeInterval?
    var at: Date

    /// True when the change got worse, used to decide whether `changed` notifies.
    var worsened: Bool { to.severity > from.severity }
}

/// Per vendor debounce and transition detection. Pure value type: feed it one
/// observation per poll and it tells you when a state has been confirmed.
///
/// Rules, from the brief:
/// - A new state must be seen on two consecutive polls before it counts.
/// - `majorOutage` is confirmed immediately.
/// - `unknown` (timeout, unreachable page) is transparent: it never confirms,
///   never notifies and does not disturb a pending change.
/// - The first real observation after launch is adopted silently.
struct VendorTracker: Hashable, Sendable {
    static let requiredPolls = 2

    private(set) var confirmed: VendorState = .unknown
    private(set) var confirmedAt: Date?
    /// When the current incident began: the vendor's own start time if known,
    /// otherwise when we first confirmed it.
    private(set) var incidentSince: Date?
    private(set) var currentIncident: Incident?
    private var pending: VendorState?
    private var pendingCount = 0

    /// True while the confirmed state is anything other than operational or unknown.
    var inIncident: Bool { confirmed.isIncident }

    mutating func observe(_ state: VendorState, incident: Incident?, at now: Date) -> VendorTransition? {
        guard state != .unknown else { return nil }

        if confirmed == .unknown {
            confirmed = state
            confirmedAt = now
            if state.isIncident {
                incidentSince = incident?.startedAt ?? now
                currentIncident = incident
            }
            return nil
        }

        if state == confirmed {
            pending = nil
            pendingCount = 0
            if state.isIncident, let incident {
                currentIncident = incident
            }
            return nil
        }

        if state == .majorOutage {
            return confirm(state, incident: incident, at: now)
        }

        if pending == state {
            pendingCount += 1
        } else {
            pending = state
            pendingCount = 1
        }
        guard pendingCount >= Self.requiredPolls else { return nil }
        return confirm(state, incident: incident, at: now)
    }

    private mutating func confirm(_ to: VendorState, incident: Incident?, at now: Date) -> VendorTransition {
        let from = confirmed
        confirmed = to
        confirmedAt = now
        pending = nil
        pendingCount = 0

        if to.isIncident && !from.isIncident {
            incidentSince = incident?.startedAt ?? now
            currentIncident = incident
            return VendorTransition(kind: .started, from: from, to: to, incident: incident, duration: nil, at: now)
        }

        if !to.isIncident && from.isIncident {
            let resolvedIncident = incident ?? currentIncident
            let duration = max(0, now.timeIntervalSince(incidentSince ?? now))
            incidentSince = nil
            currentIncident = nil
            return VendorTransition(kind: .resolved, from: from, to: to, incident: resolvedIncident, duration: duration, at: now)
        }

        if let incident { currentIncident = incident }
        return VendorTransition(kind: .changed, from: from, to: to, incident: currentIncident, duration: nil, at: now)
    }
}

/// Debounce for the baseline probes. Two consecutive failures are needed
/// before the connection is called down, and only one notification is sent
/// per outage.
struct BaselineTracker: Hashable, Sendable {
    static let requiredFailures = 2

    enum Event: Hashable, Sendable {
        case wentDown
        case restored
    }

    private(set) var consecutiveFailures = 0
    private(set) var isDown = false
    private(set) var downSince: Date?

    mutating func observe(ok: Bool, at now: Date) -> Event? {
        if ok {
            consecutiveFailures = 0
            if isDown {
                isDown = false
                downSince = nil
                return .restored
            }
            return nil
        }
        consecutiveFailures += 1
        if !isDown, consecutiveFailures >= Self.requiredFailures {
            isDown = true
            downSince = now
            return .wentDown
        }
        return nil
    }
}
