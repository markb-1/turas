import CoreLocation
import Foundation

/// Stops and routes matching a query (GET /api/v1/search). Places come from
/// MapKit on the device, not from the server.
struct SearchResponse: Decodable, Equatable, Sendable {
    let stops: [StopSearchResult]
    let routes: [RouteSearchResult]

    static let empty = SearchResponse(stops: [], routes: [])

    init(stops: [StopSearchResult], routes: [RouteSearchResult]) {
        self.stops = stops
        self.routes = routes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stops = try container.decodeIfPresent([StopSearchResult].self, forKey: .stops) ?? []
        routes = try container.decodeIfPresent([RouteSearchResult].self, forKey: .routes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case stops, routes
    }
}

/// A stop found by name. Selecting it flies the map there.
struct StopSearchResult: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    /// Modes serving the stop; unknown mode names are dropped.
    let modes: [TransportMode]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    init(id: String, name: String, lat: Double, lon: Double, modes: [TransportMode]) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.modes = modes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lat = try container.decode(Double.self, forKey: .lat)
        lon = try container.decode(Double.self, forKey: .lon)
        let rawModes = try container.decodeIfPresent([String].self, forKey: .modes) ?? []
        modes = rawModes.compactMap(TransportMode.init(rawValue:))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lat, lon, modes
    }
}

/// A route found by short name or headsign. Selecting it opens route focus.
struct RouteSearchResult: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let agencyId: String
    let agencyName: String?
    let mode: TransportMode
    let headsignOutbound: String?
    let headsignInbound: String?

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

    init(
        name: String,
        agencyId: String,
        agencyName: String? = nil,
        mode: TransportMode,
        headsignOutbound: String? = nil,
        headsignInbound: String? = nil
    ) {
        self.name = name
        self.agencyId = agencyId
        self.agencyName = agencyName
        self.mode = mode
        self.headsignOutbound = headsignOutbound
        self.headsignInbound = headsignInbound
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        agencyId = try container.decodeIfPresent(String.self, forKey: .agencyId) ?? ""
        agencyName = try container.decodeIfPresent(String.self, forKey: .agencyName)
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) ?? ""
        mode = TransportMode(rawValue: rawMode) ?? .bus
        headsignOutbound = try container.decodeIfPresent(String.self, forKey: .headsignOutbound)
        headsignInbound = try container.decodeIfPresent(String.self, forKey: .headsignInbound)
    }

    private enum CodingKeys: String, CodingKey {
        case name, mode
        case agencyId = "agency_id"
        case agencyName = "agency_name"
        case headsignOutbound = "headsign_outbound"
        case headsignInbound = "headsign_inbound"
    }
}

/// A place found by MapKit local search. Selecting it flies the map there.
struct PlaceResult: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let subtitle: String?
    let lat: Double
    let lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
