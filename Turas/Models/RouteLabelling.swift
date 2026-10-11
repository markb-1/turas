import Foundation

/// Display helpers shared by the route types that carry an agency and
/// per-direction headsigns.
protocol RouteLabelling {
    var agencyId: String { get }
    var agencyName: String? { get }
    var headsignOutbound: String? { get }
    var headsignInbound: String? { get }
}

extension RouteLabelling {
    /// Agency name for display, falling back to the agency ID.
    var operatorLabel: String {
        if let agencyName, !agencyName.isEmpty {
            return agencyName
        }
        return agencyId.isEmpty ? "Unknown operator" : "Operator \(agencyId)"
    }

    func headsign(for direction: Int) -> String? {
        let headsign = direction == 0 ? headsignOutbound : headsignInbound
        guard let headsign, !headsign.isEmpty else { return nil }
        return headsign
    }
}
