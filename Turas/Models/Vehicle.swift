import Foundation
import CoreLocation

/// A live transit vehicle parsed from the GTFS-RT feed.
struct Vehicle: Identifiable, Equatable {
    let id: String          // GTFS vehicle ID
    let tripId: String      // GTFS trip ID (for ghost bus matching)
    let routeId: String     // e.g. "39A", "Green", "DART"
    let headsign: String?   // Destination, e.g. "UCD Belfield"
    let direction: Int      // 0 = outbound, 1 = inbound
    let coordinate: CLLocationCoordinate2D
    let bearing: Float?     // Direction of travel in degrees
    let timestamp: Date     // Last reported time
    let mode: TransportMode // Bus, Luas, or Train

    static func == (lhs: Vehicle, rhs: Vehicle) -> Bool {
        lhs.id == rhs.id
            && lhs.tripId == rhs.tripId
            && lhs.routeId == rhs.routeId
            && lhs.headsign == rhs.headsign
            && lhs.direction == rhs.direction
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.bearing == rhs.bearing
            && lhs.timestamp == rhs.timestamp
            && lhs.mode == rhs.mode
    }
}
