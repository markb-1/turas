import Foundation

/// A predicted bus arrival at a specific stop, derived from GTFS-RT TripUpdates.
struct StopArrival: Identifiable {
    let id: String              // trip_id for uniqueness
    let routeId: String         // Public route name (e.g. "39A")
    let headsign: String?       // Destination name
    let delay: Int              // Delay in seconds (positive = late)
    let predictedArrival: Date  // Computed: trip start_time + stop offset + delay
    let isLive: Bool            // true = matching live vehicle, false = ghost bus
    let isCancelled: Bool       // true = trip cancelled by operator
}
