import Foundation
import os

/// Loads and caches small bundled JSON lookups (route_lookup, headsign_lookup).
///
/// Each resource is decoded once on first access and cached in memory.
/// The cache is lock-protected, so this can be called from any thread or actor.
enum BundleLoader {
    private static let logger = Logger(subsystem: "com.turas", category: "BundleLoader")
    private static let cache = LookupCache()

    /// Loads a [String: String] JSON resource from the app bundle.
    /// Returns an empty dictionary on failure (logged as a warning).
    static func loadStringLookup(resource: String) -> [String: String] {
        if let cached = cache.value(for: resource) {
            return cached
        }

        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            logger.warning("Bundle resource '\(resource).json' not found")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let lookup = try JSONDecoder().decode([String: String].self, from: data)
            cache.store(lookup, for: resource)
            return lookup
        } catch {
            logger.warning("Failed to decode '\(resource).json': \(error.localizedDescription)")
            return [:]
        }
    }
}

/// Lock-protected storage behind BundleLoader.
private final class LookupCache: @unchecked Sendable {
    private let lock = NSLock()
    private var lookups: [String: [String: String]] = [:]

    func value(for resource: String) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return lookups[resource]
    }

    func store(_ lookup: [String: String], for resource: String) {
        lock.lock()
        defer { lock.unlock() }
        lookups[resource] = lookup
    }
}
