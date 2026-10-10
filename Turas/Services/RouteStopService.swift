import Foundation
import os

/// Route stops from the bundled route_stops.json (~2 MB).
///
/// Same pattern as RouteShapeService: an actor that decodes the file once,
/// off the main thread. Routes that exist under two agencies (e.g. Dublin
/// 220 and Cork 220) have one entry per agency and direction in the file;
/// they are merged here because the file is keyed by short name only.
actor RouteStopService {
    private static let logger = Logger(subsystem: "com.turas", category: "RouteStopService")
    private var stopsByRoute: [String: [RouteStopDirection]]?

    /// - Parameter stopsByRoute: decoded stops keyed by route short name.
    ///   Pass nil (the default) to load the bundled file lazily; tests
    ///   inject data.
    init(stopsByRoute: [String: [RouteStopDirection]]? = nil) {
        self.stopsByRoute = stopsByRoute
    }

    /// Decodes the bundled file now so the first route tap does not wait for it.
    func preload() {
        _ = loaded()
    }

    /// Returns all direction entries for a route short name.
    func stops(for routeName: String) -> [RouteStopDirection] {
        loaded()[routeName] ?? []
    }

    /// Returns stops for a specific route and direction, merging every
    /// matching direction entry.
    func stops(for routeName: String, direction: Int) -> [RouteStop] {
        stops(for: routeName)
            .filter { $0.direction == direction }
            .flatMap(\.stops)
    }

    /// Directions (0/1) that have stops for this route.
    func directions(for routeName: String) -> Set<Int> {
        Set(stops(for: routeName).filter { !$0.stops.isEmpty }.map(\.direction))
    }

    /// Returns deduplicated stops within `radius` metres of the given point,
    /// served by any route in `routeNames`, nearest first. Each NearbyStop
    /// lists every route name that serves it.
    func nearbyStops(
        routeNames: Set<String>,
        latitude: Double,
        longitude: Double,
        radius: Double
    ) -> [NearbyStop] {
        let allStops = loaded()
        var seen: [String: (stop: RouteStop, routeNames: Set<String>, distance: Double)] = [:]

        for routeName in routeNames {
            guard let directions = allStops[routeName] else { continue }
            for dir in directions {
                for stop in dir.stops {
                    let d = GeoUtils.straightLineDistance(
                        lat1: latitude, lon1: longitude,
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
            .sorted { ($0.distance, $0.stop.id) < ($1.distance, $1.stop.id) }
            .map { NearbyStop(stop: $0.stop, routeNames: $0.routeNames, distance: $0.distance) }
    }

    private func loaded() -> [String: [RouteStopDirection]] {
        if let stopsByRoute {
            return stopsByRoute
        }
        let decoded = Self.decodeBundledStops()
        stopsByRoute = decoded
        return decoded
    }

    private static func decodeBundledStops() -> [String: [RouteStopDirection]] {
        guard let url = Bundle.main.url(forResource: "route_stops", withExtension: "json") else {
            logger.warning("route_stops.json not found in bundle")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: [RouteStopDirection]].self, from: data)
        } catch {
            logger.warning("Failed to decode route_stops.json: \(error.localizedDescription)")
            return [:]
        }
    }
}
