import Foundation
import os

/// Loads route shape polylines from the bundled JSON on demand.
///
/// Shapes are loaded lazily — the full JSON is only parsed when
/// the first route is requested. After that, lookups are O(1).
/// The JSON is ~2.4MB so the initial parse is fast (<100ms from local bundle).
final class RouteShapeService {
    private static let logger = Logger(subsystem: "com.turas", category: "RouteShapeService")
    private var shapes: [String: [RouteShape]]?

    /// Returns the polyline shapes for a given route short name (e.g. "39A").
    /// Returns an empty array if the route has no shape data.
    func shapes(for routeName: String) -> [RouteShape] {
        if shapes == nil {
            loadShapes()
        }
        return shapes?[routeName] ?? []
    }

    private func loadShapes() {
        guard let url = Bundle.main.url(forResource: "route_shapes", withExtension: "json") else {
            Self.logger.warning("route_shapes.json not found in bundle")
            shapes = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            shapes = try JSONDecoder().decode([String: [RouteShape]].self, from: data)
        } catch {
            Self.logger.warning("Failed to decode route_shapes.json: \(error.localizedDescription)")
            shapes = [:]
        }
    }
}
