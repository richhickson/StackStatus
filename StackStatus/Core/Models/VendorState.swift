import Foundation

/// The normalised health of one vendor. Every platform adapter maps its own
/// vocabulary onto these six values.
enum VendorState: String, Codable, CaseIterable, Sendable {
    case operational
    case degraded
    case partialOutage
    case majorOutage
    case maintenance
    case unknown

    /// Ordering used to pick the worst state across vendors. Maintenance ranks
    /// below degraded, as the brief requires. Unknown ranks lowest because a
    /// timed out fetch must never look like an outage.
    var severity: Int {
        switch self {
        case .unknown: return 0
        case .operational: return 1
        case .maintenance: return 2
        case .degraded: return 3
        case .partialOutage: return 4
        case .majorOutage: return 5
        }
    }

    /// True for any state the vendor has actively reported as not normal.
    var isIncident: Bool {
        switch self {
        case .degraded, .partialOutage, .majorOutage, .maintenance: return true
        case .operational, .unknown: return false
        }
    }

    var label: String {
        switch self {
        case .operational: return "Operational"
        case .degraded: return "Degraded"
        case .partialOutage: return "Partial outage"
        case .majorOutage: return "Major outage"
        case .maintenance: return "Maintenance"
        case .unknown: return "Unknown"
        }
    }

    static func worst(of states: some Sequence<VendorState>) -> VendorState {
        states.max(by: { $0.severity < $1.severity }) ?? .unknown
    }
}
