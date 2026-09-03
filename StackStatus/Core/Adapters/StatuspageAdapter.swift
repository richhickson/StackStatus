import Foundation

/// Atlassian Statuspage. Polls the tiny status.json and only reaches for the
/// incident list when the indicator says something is going on.
struct StatuspageAdapter: StatusFeedAdapter {
    let platform = Platform.statuspage

    static let statusPath = "/api/v2/status.json"
    static let unresolvedPath = "/api/v2/incidents/unresolved.json"
    static let activeMaintenancePath = "/api/v2/scheduled-maintenances/active.json"

    static func state(forIndicator indicator: String) -> VendorState {
        switch indicator.lowercased() {
        case "none": return .operational
        case "minor": return .degraded
        case "major": return .partialOutage
        case "critical": return .majorOutage
        case "maintenance": return .maintenance
        default: return .unknown
        }
    }

    func fetch(_ vendor: Vendor, using http: HTTPFetching, conditional: Bool) async throws -> FetchOutcome {
        let statusURL = vendor.baseURL.appendingStatusPath(Self.statusPath)
        guard case .success(let data, _, _) = try await http.get(statusURL, conditional: conditional) else {
            return .unchanged
        }
        let json = try data.jsonObject()
        guard let status = json.object("status"), let indicator = status.string("indicator") else {
            throw AdapterError.malformed("status.json")
        }
        let state = Self.state(forIndicator: indicator)
        let description = status.string("description")

        var incidents: [Incident] = []
        if state.isIncident {
            let isMaintenance = state == .maintenance
            let path = isMaintenance ? Self.activeMaintenancePath : Self.unresolvedPath
            let key = isMaintenance ? "scheduled_maintenances" : "incidents"
            // Detail is best effort: the indicator alone is enough for the state.
            if let detail = try? await http.get(vendor.baseURL.appendingStatusPath(path), conditional: false).data,
               let detailJSON = try? detail.jsonObject() {
                incidents = detailJSON.array(key).compactMap { Self.incident(from: $0, pageURL: vendor.pageURL) }
            }
        }
        return .snapshot(FeedSnapshot(state: state, incidents: incidents, description: description))
    }

    static func incident(from json: JSONObject, pageURL: URL) -> Incident? {
        guard let id = json.string("id"), let name = json.string("name") else { return nil }
        let impact = json.string("impact")
        return Incident(
            id: id,
            title: name,
            url: json.url("shortlink") ?? pageURL,
            status: json.string("status"),
            impact: impact,
            startedAt: json.date("started_at") ?? json.date("created_at"),
            updatedAt: json.date("updated_at"),
            isMaintenance: impact == "maintenance"
        )
    }
}
