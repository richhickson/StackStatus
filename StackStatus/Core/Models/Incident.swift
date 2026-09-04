import Foundation

/// An incident or maintenance window reported by a vendor's status page.
struct Incident: Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var url: URL?
    /// The platform's own status word, for display: "investigating", "monitoring" and so on.
    var status: String?
    /// The platform's own impact word, if any: "minor", "major", "critical", "maintenance".
    var impact: String?
    var startedAt: Date?
    var updatedAt: Date?
    var isMaintenance: Bool

    init(
        id: String,
        title: String,
        url: URL? = nil,
        status: String? = nil,
        impact: String? = nil,
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        isMaintenance: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.status = status
        self.impact = impact
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.isMaintenance = isMaintenance
    }
}

/// What one adapter fetch produced.
struct FeedSnapshot: Hashable, Sendable {
    var state: VendorState
    var incidents: [Incident]
    /// The page's own one line description, such as "All Systems Operational".
    var description: String?
    var fetchedAt: Date

    init(state: VendorState, incidents: [Incident] = [], description: String? = nil, fetchedAt: Date = Date()) {
        self.state = state
        self.incidents = incidents
        self.description = description
        self.fetchedAt = fetchedAt
    }

    /// The incident to show under the vendor row: the first non maintenance
    /// one if there is one, otherwise the first of any kind.
    var primaryIncident: Incident? {
        incidents.first(where: { !$0.isMaintenance }) ?? incidents.first
    }
}

/// The result of asking an adapter for the current state of a vendor.
enum FetchOutcome: Sendable {
    /// The server answered 304 Not Modified. Keep whatever was shown before.
    case unchanged
    case snapshot(FeedSnapshot)
}
