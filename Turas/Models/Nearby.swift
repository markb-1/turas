import CoreLocation
import Foundation

/// What is leaving near a point, computed by the server (GET /api/v1/nearby).
///
/// `stops` lists only the stops that `departures` reference; they become the
/// map pins. Lists are `[]` on the wire, never null, but a missing or null
/// list decodes as empty rather than failing the whole response.
struct NearbyResponse: Decodable, Equatable, Sendable {
    let stops: [DepartureStop]
    let departures: [NearbyDeparture]

    static let empty = NearbyResponse(stops: [], departures: [])

    init(stops: [DepartureStop], departures: [NearbyDeparture]) {
        self.stops = stops
        self.departures = departures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stops = try container.decodeIfPresent([DepartureStop].self, forKey: .stops) ?? []
        departures = try container.decodeIfPresent([NearbyDeparture].self, forKey: .departures) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case stops, departures
    }

    func stop(withId id: String) -> DepartureStop? {
        stops.first { $0.id == id }
    }
}

/// A stop the timeline uses, with its distance from the query point.
struct DepartureStop: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let distanceM: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, lat, lon
        case distanceM = "distance_m"
    }
}

/// One timeline row: a route and direction, from the nearest stop that has
/// a departure in the window, with its next (up to three) times.
struct NearbyDeparture: Decodable, Identifiable, Hashable, Sendable {
    let route: String
    let agencyId: String
    let direction: Int
    /// The trip's headsign; the server omits it when none is known.
    let headsign: String?
    let stopId: String
    let distanceM: Int
    let times: [DepartureTime]

    /// One row per (route, agency, direction), so that is the identity.
    var id: String { "\(agencyId)|\(route)|\(direction)" }
    var routeRef: RouteRef { RouteRef(name: route, agencyId: agencyId) }
    var firstTime: DepartureTime? { times.first }

    /// What the row shows as the destination: the headsign, else the
    /// direction, so a row is never blank.
    var destination: String {
        if let headsign, !headsign.isEmpty { return headsign }
        return "Direction \(direction)"
    }

    enum CodingKeys: String, CodingKey {
        case route, direction, headsign, times
        case agencyId = "agency_id"
        case stopId = "stop_id"
        case distanceM = "distance_m"
    }
}

/// Where a departure time came from. Live and realtime are shown in the
/// brand colour; timetable-only times are muted.
enum DepartureSource: String, Decodable, Sendable {
    /// A vehicle is reporting for the trip (or a Luas forecast).
    case live
    /// A trip update exists but no vehicle reports.
    case realtime
    /// Scheduled time only.
    case timetable

    var isLive: Bool { self != .timetable }
}

/// One departure time of a trip at a stop.
struct DepartureTime: Decodable, Hashable, Sendable {
    let tripId: String
    let at: Date
    /// Seconds late (positive) or early.
    let delay: Int
    let source: DepartureSource
    /// A cancelled trip keeps its timetabled time.
    let cancelled: Bool

    init(tripId: String, at: Date, delay: Int, source: DepartureSource, cancelled: Bool) {
        self.tripId = tripId
        self.at = at
        self.delay = delay
        self.source = source
        self.cancelled = cancelled
    }

    /// An unknown source reads as timetable and a missing `cancelled` as
    /// false, so a newer server never blanks the timeline.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tripId = try container.decode(String.self, forKey: .tripId)
        at = try container.decode(Date.self, forKey: .at)
        delay = try container.decodeIfPresent(Int.self, forKey: .delay) ?? 0
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        source = DepartureSource(rawValue: rawSource) ?? .timetable
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case at, delay, source, cancelled
        case tripId = "trip_id"
    }
}
