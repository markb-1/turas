import CoreLocation
import Foundation

/// A live transit vehicle reported by the Turas server.
///
/// Position is stored as plain doubles so `Equatable` can be synthesized;
/// `coordinate` builds the MapKit value on demand.
struct Vehicle: Identifiable, Equatable, Sendable {
    let id: String          // Vehicle ID (Irish Rail: train code)
    let tripId: String      // GTFS trip ID (for ghost bus matching)
    let routeId: String     // Public route name, e.g. "39A", "Green", "DART"
    let headsign: String?   // Destination, e.g. "UCD Belfield"
    let direction: Int      // 0 = outbound, 1 = inbound
    let latitude: Double
    let longitude: Double
    let bearing: Float?     // Direction of travel in degrees clockwise from north
    let timestamp: Date     // Last reported time
    let mode: TransportMode // Bus, Luas, or Train

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
