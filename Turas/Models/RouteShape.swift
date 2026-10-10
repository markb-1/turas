import CoreLocation
import Foundation

/// A simplified polyline for one direction of a route.
///
/// Decoded from the bundled `route_shapes.json`, which was pre-processed
/// from the static GTFS `shapes.txt` using Douglas-Peucker simplification.
/// Each shape typically has ~150-200 coordinate points.
struct RouteShape: Decodable, Sendable {
    let direction: Int          // 0 = outbound, 1 = inbound
    let coordinates: [[Double]] // [[lat, lon], ...]

    /// Converts the raw [lat, lon] pairs to CLLocationCoordinate2D for MapKit.
    var clCoordinates: [CLLocationCoordinate2D] {
        coordinates.map {
            CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])
        }
    }
}
