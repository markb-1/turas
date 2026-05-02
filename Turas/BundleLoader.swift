import Foundation
import os

/// Loads and caches bundled JSON resources.
///
/// Each JSON resource is decoded once on first access and cached in memory.
/// Shared across services to avoid redundant I/O and decoding.
enum BundleLoader {
    private static let logger = Logger(subsystem: "com.turas", category: "BundleLoader")

    /// Cache for [String: String] lookups (route_lookup, headsign_lookup).
    private static var stringLookups: [String: [String: String]] = [:]

    /// Loads a [String: String] JSON resource from the app bundle.
    /// Returns an empty dictionary on failure (logged as a warning).
    static func loadStringLookup(resource: String) -> [String: String] {
        if let cached = stringLookups[resource] {
            return cached
        }

        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            logger.warning("Bundle resource '\(resource).json' not found")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let lookup = try JSONDecoder().decode([String: String].self, from: data)
            stringLookups[resource] = lookup
            return lookup
        } catch {
            logger.warning("Failed to decode '\(resource).json': \(error.localizedDescription)")
            return [:]
        }
    }
}
