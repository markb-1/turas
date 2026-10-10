import CoreLocation
import Foundation

/// A stop along a specific route direction.
///
/// Decoded from the bundled route_stops.json. The server's /api/v1/stops
/// returns the same shape (plus a `luas_code` the app does not need: the
/// server resolves Luas stop codes itself).
struct RouteStop: Codable, Identifiable, Hashable, Sendable {
    let id: String          // GTFS stop_id
    let name: String        // Human-readable stop name
    let lat: Double
    let lon: Double
    let seq: Int            // Stop sequence along the route
    let t: Int              // Seconds from first stop (schedule offset)

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// One direction's stops for a route, decoded from route_stops.json.
struct RouteStopDirection: Codable, Sendable {
    let direction: Int
    let stops: [RouteStop]
}
