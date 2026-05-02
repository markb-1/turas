import CoreLocation
import Foundation
import os

/// Loads route stop data from the bundled JSON on demand.
/// Same lazy-loading pattern as RouteShapeService.
final class RouteStopService {
    private static let logger = Logger(subsystem: "com.turas", category: "RouteStopService")
    private var allStops: [String: [RouteStopDirection]]?

    /// Returns all direction entries for a route short name.
    func stops(for routeName: String) -> [RouteStopDirection] {
        if allStops == nil { loadStops() }
        return allStops?[routeName] ?? []
    }

    /// Returns stops for a specific route and direction.
    /// Merges stops from all matching direction entries (handles routes
    /// that span multiple regions, e.g. Dublin 220 + Cork 220).
    func stops(for routeName: String, direction: Int) -> [RouteStop] {
        stops(for: routeName)
            .filter { $0.direction == direction }
            .flatMap(\.stops)
    }

    /// Returns deduplicated stops within `radius` metres of `center`,
    /// filtered to routes in `routeNames`. Each NearbyStop includes
    /// all route names that serve it.
    func nearbyStops(
        routeNames: Set<String>,
        center: CLLocationCoordinate2D,
        radius: Double
    ) -> [NearbyStop] {
        if allStops == nil { loadStops() }
        guard let allStops else { return [] }

        var seen: [String: (stop: RouteStop, routeNames: Set<String>, distance: Double)] = [:]

        for routeName in routeNames {
            guard let directions = allStops[routeName] else { continue }
            for dir in directions {
                for stop in dir.stops {
                    let d = GeoUtils.straightLineDistance(
                        lat1: center.latitude, lon1: center.longitude,
                        lat2: stop.lat, lon2: stop.lon
                    )
                    guard d <= radius else { continue }

                    if var existing = seen[stop.id] {
                        existing.routeNames.insert(routeName)
                        seen[stop.id] = existing
                    } else {
                        seen[stop.id] = (stop: stop, routeNames: [routeName], distance: d)
                    }
                }
            }
        }

        return seen.values
            .sorted { $0.distance < $1.distance }
            .map { NearbyStop(stop: $0.stop, routeNames: $0.routeNames, distance: $0.distance) }
    }

    private func loadStops() {
        guard let url = Bundle.main.url(forResource: "route_stops", withExtension: "json") else {
            Self.logger.warning("route_stops.json not found in bundle")
            allStops = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            allStops = try JSONDecoder().decode([String: [RouteStopDirection]].self, from: data)
        } catch {
            Self.logger.warning("Failed to decode route_stops.json: \(error.localizedDescription)")
            allStops = [:]
        }
    }
}
