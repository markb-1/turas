import Foundation
import os

/// Route stops from the bundled route_stops.json (~2 MB).
///
/// An actor that decodes the file once, off the main thread. Routes that exist under two agencies (e.g. Dublin
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
