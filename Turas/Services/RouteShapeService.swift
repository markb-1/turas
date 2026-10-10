import Foundation
import os

/// Route shape polylines from the bundled route_shapes.json (~2 MB).
///
/// An actor, so the JSON is decoded on the actor's executor rather than the
/// main thread. The file is decoded once, on first use or on `preload()`;
/// after that lookups are dictionary reads.
actor RouteShapeService {
    private static let logger = Logger(subsystem: "com.turas", category: "RouteShapeService")
    private var shapesByRoute: [String: [RouteShape]]?

    /// - Parameter shapes: decoded shapes keyed by route short name. Pass nil
    ///   (the default) to load the bundled file lazily; tests inject data.
    init(shapes: [String: [RouteShape]]? = nil) {
        self.shapesByRoute = shapes
    }

    /// Decodes the bundled file now so the first route tap does not wait for it.
    func preload() {
        _ = loaded()
    }

    /// Returns the polyline shapes for a route short name (e.g. "39A").
    /// Returns an empty array if the route has no shape data.
    func shapes(for routeName: String) -> [RouteShape] {
        loaded()[routeName] ?? []
    }

    /// Directions (0/1) that have a shape for this route.
    func directions(for routeName: String) -> Set<Int> {
        Set(shapes(for: routeName).map(\.direction))
    }

    private func loaded() -> [String: [RouteShape]] {
        if let shapesByRoute {
            return shapesByRoute
        }
        let decoded = Self.decodeBundledShapes()
        shapesByRoute = decoded
        return decoded
    }

    private static func decodeBundledShapes() -> [String: [RouteShape]] {
        guard let url = Bundle.main.url(forResource: "route_shapes", withExtension: "json") else {
            logger.warning("route_shapes.json not found in bundle")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: [RouteShape]].self, from: data)
        } catch {
            logger.warning("Failed to decode route_shapes.json: \(error.localizedDescription)")
            return [:]
        }
    }
}
