import Foundation

/// incident.io status pages. Polls `/api/v1/summary` (about 150 bytes when
/// quiet) and falls back to the `/proxy/<host>` document the page's own front
/// end loads if a page does not expose the summary API.
struct IncidentIOAdapter: StatusFeedAdapter {
    let platform = Platform.incidentio

    static let summaryPath = "/api/v1/summary"

    static func proxyURL(for baseURL: URL) -> URL? {
        guard let host = baseURL.host else { return nil }
        return baseURL.appendingStatusPath("/proxy/\(host)")
    }

    static func state(forComponentStatus status: String) -> VendorState {
        switch status.lowercased() {
        case "operational": return .operational
        case "degraded_performance": return .degraded
        case "partial_outage": return .partialOutage
        case "full_outage": return .majorOutage
        case "under_maintenance": return .maintenance
        default: return .degraded
        }
    }

    func fetch(_ vendor: Vendor, using http: HTTPFetching, conditional: Bool) async throws -> FetchOutcome {
        let summaryURL = vendor.baseURL.appendingStatusPath(Self.summaryPath)
        do {
            guard case .success(let data, _, _) = try await http.get(summaryURL, conditional: conditional) else {
                return .unchanged
            }
            return .snapshot(try Self.parseSummary(try data.jsonObject(), pageURL: vendor.pageURL))
        } catch HTTPError.status(404, _) {
            guard let proxyURL = Self.proxyURL(for: vendor.baseURL) else { throw AdapterError.malformed("base URL") }
            guard case .success(let data, _, _) = try await http.get(proxyURL, conditional: conditional) else {
                return .unchanged
            }
            let json = try data.jsonObject()
            return .snapshot(try Self.parseSummary(json.object("summary") ?? json, pageURL: vendor.pageURL))
        }
    }

    /// Shared by both endpoints: they carry the same `ongoing_incidents` and
    /// maintenance arrays.
    static func parseSummary(_ json: JSONObject, pageURL: URL) throws -> FeedSnapshot {
        guard json["ongoing_incidents"] != nil || json["in_progress_maintenances"] != nil || json["scheduled_maintenances"] != nil else {
            throw AdapterError.malformed("incident.io summary")
        }

        var worst = VendorState.operational
        var incidents: [Incident] = []

        for raw in json.array("ongoing_incidents") {
            let componentStates = raw.array("affected_components").compactMap { component -> VendorState? in
                guard let status = component.string("status") else { return nil }
                return Self.state(forComponentStatus: status)
            }
            var incidentState = VendorState.worst(of: componentStates)
            if !incidentState.isIncident { incidentState = .degraded }
            if incidentState.severity > worst.severity { worst = incidentState }
            if let incident = Self.incident(from: raw, pageURL: pageURL, isMaintenance: false) {
                incidents.append(incident)
            }
        }

        for raw in json.array("in_progress_maintenances") {
            if worst == .operational { worst = .maintenance }
            if let incident = Self.incident(from: raw, pageURL: pageURL, isMaintenance: true) {
                incidents.append(incident)
            }
        }

        let description = worst == .operational ? "All Systems Operational" : nil
        return FeedSnapshot(state: worst, incidents: incidents, description: description)
    }

    static func incident(from json: JSONObject, pageURL: URL, isMaintenance: Bool) -> Incident? {
        guard let id = json.string("id"), let name = json.string("name") else { return nil }
        let updates = json.array("updates")
        let updateDates = updates.compactMap { $0.date("published_at") }
        let startedAt = updateDates.min() ?? json.date("published_at") ?? json.date("started_at")
        let updatedAt = updateDates.max() ?? json.date("updated_at")
        return Incident(
            id: id,
            title: name,
            url: pageURL.appendingStatusPath("/incidents/\(id)"),
            status: json.string("status"),
            impact: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            isMaintenance: isMaintenance
        )
    }
}
