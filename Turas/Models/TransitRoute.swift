import Foundation

/// A selectable route, as listed by the server's /api/v1/routes (or built
/// from the bundled lookups when the server has never been reached).
struct TransitRoute: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let agencyId: String
    let agencyName: String?
    let headsignOutbound: String?
    let headsignInbound: String?
    /// Directions (0/1) that have stops. Empty when unknown.
    let directions: [Int]

    var id: String { "\(agencyId)|\(name)" }
    var ref: RouteRef { RouteRef(name: name, agencyId: agencyId) }

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

    enum CodingKeys: String, CodingKey {
        case name
        case agencyId = "agency_id"
        case agencyName = "agency_name"
        case headsignOutbound = "headsign_outbound"
        case headsignInbound = "headsign_inbound"
        case directions
    }

    init(
        name: String,
        agencyId: String,
        agencyName: String? = nil,
        headsignOutbound: String? = nil,
        headsignInbound: String? = nil,
        directions: [Int] = []
    ) {
        self.name = name
        self.agencyId = agencyId
        self.agencyName = agencyName
        self.headsignOutbound = headsignOutbound
        self.headsignInbound = headsignInbound
        self.directions = directions
    }

    /// Tolerates servers that predate agency IDs and direction lists.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        agencyId = try container.decodeIfPresent(String.self, forKey: .agencyId) ?? ""
        agencyName = try container.decodeIfPresent(String.self, forKey: .agencyName)
        headsignOutbound = try container.decodeIfPresent(String.self, forKey: .headsignOutbound)
        headsignInbound = try container.decodeIfPresent(String.self, forKey: .headsignInbound)
        directions = try container.decodeIfPresent([Int].self, forKey: .directions) ?? []
    }
}
