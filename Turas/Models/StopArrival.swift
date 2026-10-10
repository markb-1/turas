import Foundation

/// A predicted arrival at a stop, computed by the server from the GTFS
/// schedule and GTFS-RT trip updates (or the Luas Forecast API).
struct StopArrival: Identifiable, Equatable, Sendable {
    let id: String              // trip_id for uniqueness
    let routeId: String         // Public route name (e.g. "39A")
    let headsign: String?       // Destination name
    let delay: Int              // Delay in seconds (positive = late)
    let predictedArrival: Date
    let isLive: Bool            // true = a vehicle is reporting for this trip, false = scheduled ("ghost")
    let isCancelled: Bool       // true = trip cancelled by operator
}
