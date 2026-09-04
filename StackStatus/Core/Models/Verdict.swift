import Foundation

/// What the vendor's own status feed says, reduced to the three cases the
/// verdict matrix cares about.
enum FeedSignal: Hashable, Sendable {
    case ok
    case incident
    case unreachable
}

/// What the vendor's probes say. `none` means the vendor declares no probes.
enum ProbeSignal: Hashable, Sendable {
    case ok
    case failing
    case none
}

/// What the always on baseline probes say. `unknown` before the first cycle completes.
enum BaselineSignal: Hashable, Sendable {
    case ok
    case failing
    case unknown
}

/// The answer to "them, me, or the internet" for one vendor.
enum Verdict: Hashable, Sendable {
    /// Feed reports an incident and our connection is fine: it is them.
    case vendorIncident
    /// Feed says fine, our probe of them fails, our connection is fine: probably them, not posted yet.
    case likelyVendorProblem
    /// Baseline is failing: it is us.
    case yourConnection
    /// Feed says fine, probes fine, baseline fine.
    case allGood
    /// Status page unreachable while our connection is fine, or nothing checked yet.
    case unknown

    var label: String {
        switch self {
        case .vendorIncident: return "Vendor incident"
        case .likelyVendorProblem: return "Looks like a vendor problem they have not posted yet"
        case .yourConnection: return "Your connection"
        case .allGood: return "All good"
        case .unknown: return "Unknown"
        }
    }
}

/// How the menubar icon should be tinted.
enum Tone: Hashable, Sendable {
    case good
    case warning
    case bad
    case neutral
}

/// The one line shown at the top of the popover, plus the icon tone it implies.
struct Headline: Hashable, Sendable {
    var text: String
    var tone: Tone
}
