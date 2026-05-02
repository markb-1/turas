import CoreLocation

/// A deduplicated stop near the user's location, with all routes that serve it.
/// Used in the idle state (no route selected) to show nearby stops on the map.
struct NearbyStop: Identifiable {
    let stop: RouteStop
    let routeNames: Set<String>
    let distance: Double // metres from user

    var id: String { stop.id }
    var coordinate: CLLocationCoordinate2D { stop.coordinate }
}
