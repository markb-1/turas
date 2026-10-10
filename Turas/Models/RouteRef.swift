import Foundation

/// A route as the server identifies it: a short name plus the agency that
/// runs it. Short names alone are ambiguous (220 is both Dublin Bus and Bus
/// Éireann). `agencyId` is the prefix of the GTFS route_id, e.g. "5249".
///
/// A nil agency means "not known": the server then picks the agency running
/// the most trips under that name.
struct RouteRef: Hashable, Codable, Sendable {
    let name: String
    let agencyId: String?

    init(name: String, agencyId: String? = nil) {
        self.name = name
        if let agencyId, !agencyId.isEmpty {
            self.agencyId = agencyId
        } else {
            self.agencyId = nil
        }
    }

    /// Whether a vehicle reported under `routeId` / `agencyId` belongs to
    /// this route. An unknown agency on either side matches by name alone.
    func matches(routeId: String, agencyId vehicleAgency: String?) -> Bool {
        guard routeId == name else { return false }
        guard let agencyId, let vehicleAgency, !vehicleAgency.isEmpty else { return true }
        return agencyId == vehicleAgency
    }
}
