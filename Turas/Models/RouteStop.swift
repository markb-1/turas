import Foundation
import CoreLocation

/// A stop along a specific route direction, decoded from bundled route_stops.json.
struct RouteStop: Decodable, Identifiable {
    let id: String          // GTFS stop_id
    let name: String        // Human-readable stop name
    let lat: Double
    let lon: Double
    let seq: Int            // Stop sequence along the route
    let t: Int              // Seconds from first stop (schedule offset for arrival calc)
    let luasCode: String?   // Luas Forecast API stop code (e.g. "OGP"), nil for non-Luas stops

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// One direction's stops for a route, decoded from route_stops.json.
struct RouteStopDirection: Decodable {
    let direction: Int
    let stops: [RouteStop]
}
