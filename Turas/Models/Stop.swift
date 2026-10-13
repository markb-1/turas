import CoreLocation
import Foundation

/// A Luas or train station for the map (GET /api/v1/stations): one entry
/// per Luas stop (the server merges its two platforms into the lower stop
/// ID) or train station.
struct Station: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// The stop a departures answer describes.
struct StopInfo: Decodable, Hashable, Sendable {
    let id: String
    let name: String
    /// The public stop number ("7602"); nil when the feed has none (the
    /// server omits an empty code).
    let code: String?
    let lat: Double
    let lon: Double
    /// Modes of the routes serving the stop; unknown names are dropped.
    let modes: [TransportMode]

    init(id: String, name: String, code: String?, lat: Double, lon: Double, modes: [TransportMode]) {
        self.id = id
        self.name = name
        self.code = code
        self.lat = lat
        self.lon = lon
        self.modes = modes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawCode = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        code = rawCode.isEmpty ? nil : rawCode
        lat = try container.decode(Double.self, forKey: .lat)
        lon = try container.decode(Double.self, forKey: .lon)
        let rawModes = try container.decodeIfPresent([String].self, forKey: .modes) ?? []
        modes = rawModes.compactMap(TransportMode.init(rawValue:))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, code, lat, lon, modes
    }
}

/// Everything leaving one stop (GET /api/v1/departures). The rows have
/// the `/nearby` shape, with `distance_m` 0 and `stop_id` the requested
/// stop; a missing or null list decodes as empty.
struct StopDepartures: Decodable, Equatable, Sendable {
    let stop: StopInfo
    let departures: [NearbyDeparture]

    init(stop: StopInfo, departures: [NearbyDeparture]) {
        self.stop = stop
        self.departures = departures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stop = try container.decode(StopInfo.self, forKey: .stop)
        departures = try container.decodeIfPresent([NearbyDeparture].self, forKey: .departures) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case stop, departures
    }
}

/// What the stop view was opened for: a pin on the map or a stop search
/// result. A stop view has one mode (the rows carry none, and a stop
/// serves one mode in TFI's feed): it colours the badges and picks the
/// route focus endpoint.
struct StopTarget: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let mode: TransportMode

    init(id: String, name: String, lat: Double, lon: Double, mode: TransportMode) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.mode = mode
    }

    /// A bus pin, from `/nearby`'s stops.
    init(_ stop: DepartureStop, mode: TransportMode) {
        self.init(id: stop.id, name: stop.name, lat: stop.lat, lon: stop.lon, mode: mode)
    }

    /// A Luas or train station pin.
    init(_ station: Station, mode: TransportMode) {
        self.init(id: station.id, name: station.name, lat: station.lat, lon: station.lon, mode: mode)
    }

    /// A stop search result: the current mode when the stop serves it,
    /// else the stop's own first mode, else the current mode.
    init(_ result: StopSearchResult, preferring mode: TransportMode) {
        let stopMode = result.modes.contains(mode) ? mode : (result.modes.first ?? mode)
        self.init(id: result.id, name: result.name, lat: result.lat, lon: result.lon, mode: stopMode)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
