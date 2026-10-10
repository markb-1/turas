import Foundation
import os

/// Routes and stops, from the server when possible.
///
/// Lookups never wait on the network unless the data is not cached:
///
/// - Routes: memory, then the disk cache (any age), then the bundled
///   route_lookup.json / headsign_lookup.json. `refreshRoutesIfStale()`
///   (run in the background at launch) re-fetches route lists whose cache
///   is missing or older than 7 days.
/// - Stops: memory, then a fresh disk cache, then the server, then a stale
///   disk cache, then the bundled route_stops.json.
///
/// The cache is JSON in Caches/StaticData. Shapes stay bundled: the server
/// does not serve them.
actor StaticDataStore {
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private static let logger = Logger(subsystem: "com.turas", category: "StaticDataStore")

    private let source: StaticDataSource
    private let bundledStops: RouteStopService
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private let bundledRoutes: @Sendable () -> [TransportMode: [TransitRoute]]

    private var routesByMode: [TransportMode: [TransitRoute]] = [:]
    private var stopsByKey: [String: [RouteStop]] = [:]

    /// - Parameters:
    ///   - cacheDirectory: where cached JSON lives; nil disables the disk cache.
    ///   - now: clock, injectable for tests.
    ///   - bundledRoutes: fallback route lists, injectable for tests.
    init(
        source: StaticDataSource,
        bundledStops: RouteStopService,
        cacheDirectory: URL? = StaticDataStore.defaultCacheDirectory(),
        now: @escaping @Sendable () -> Date = { Date() },
        bundledRoutes: @escaping @Sendable () -> [TransportMode: [TransitRoute]] = { StaticDataStore.bundledRouteLists() }
    ) {
        self.source = source
        self.bundledStops = bundledStops
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.bundledRoutes = bundledRoutes
    }

    static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StaticData", isDirectory: true)
    }

    // MARK: - Routes

    /// Routes for a mode, sorted by name then agency. Never touches the network.
    func routes(for mode: TransportMode) -> [TransitRoute] {
        if let routes = routesByMode[mode] {
            return routes
        }
        if let cached = readCache([TransitRoute].self, file: Self.routesFile(mode)), !cached.value.isEmpty {
            routesByMode[mode] = cached.value
            return cached.value
        }
        let bundled = bundledRoutes()[mode] ?? []
        routesByMode[mode] = bundled
        return bundled
    }

    /// Re-fetches every route list whose cache is missing or older than
    /// `maxAge`. Failures keep the data already in hand. Returns the modes
    /// whose lists changed.
    @discardableResult
    func refreshRoutesIfStale() async -> Set<TransportMode> {
        var refreshed: Set<TransportMode> = []
        for mode in TransportMode.allCases {
            if let cached = readCache([TransitRoute].self, file: Self.routesFile(mode)),
               isFresh(cached.fetchedAt), !cached.value.isEmpty {
                if routesByMode[mode] != cached.value {
                    routesByMode[mode] = cached.value
                    refreshed.insert(mode)
                }
                continue
            }
            do {
                let routes = try await source.fetchRoutes(mode: mode)
                // An empty list means a server problem, not a network with no
                // routes: keep what we have.
                guard !routes.isEmpty else { continue }
                writeCache(routes, file: Self.routesFile(mode))
                if routesByMode[mode] != routes {
                    routesByMode[mode] = routes
                    refreshed.insert(mode)
                }
            } catch {
                Self.logger.warning("Route refresh for \(mode.rawValue) failed: \(error.localizedDescription)")
            }
        }
        return refreshed
    }

    // MARK: - Stops

    /// Ordered stops for a route in one direction.
    func stops(for route: RouteRef, direction: Int) async -> [RouteStop] {
        if let stops = await serverStops(for: route, direction: direction), !stops.isEmpty {
            return stops
        }
        if let stale = readCache([RouteStop].self, file: Self.stopsFile(route, direction)), !stale.value.isEmpty {
            return stale.value
        }
        return await bundledStops.stops(for: route.name, direction: direction)
    }

    /// The route the user means by `name` at a stop: the only route of that
    /// name in the mode or, when two agencies share the name, the one whose
    /// stops include the stop. Falls back to a route without an agency
    /// (the server's default) when that cannot be decided.
    func resolve(name: String, mode: TransportMode, atStop stopId: String?) async -> RouteRef {
        let candidates = routes(for: mode).filter { $0.name == name }
        if candidates.count == 1 {
            return candidates[0].ref
        }
        guard candidates.count > 1, let stopId else {
            return RouteRef(name: name)
        }
        for candidate in candidates {
            let directions = candidate.directions.isEmpty ? [0, 1] : candidate.directions
            for direction in directions {
                // Only trust server data here: the bundled file merges both
                // agencies' stops under one name.
                if let stops = await serverStops(for: candidate.ref, direction: direction),
                   stops.contains(where: { $0.id == stopId }) {
                    return candidate.ref
                }
            }
        }
        return RouteRef(name: name)
    }

    /// Stops from memory, a fresh disk cache or the server; nil when none of
    /// those has them.
    private func serverStops(for route: RouteRef, direction: Int) async -> [RouteStop]? {
        let file = Self.stopsFile(route, direction)
        if let stops = stopsByKey[file] {
            return stops
        }
        if let cached = readCache([RouteStop].self, file: file), isFresh(cached.fetchedAt) {
            stopsByKey[file] = cached.value
            return cached.value
        }
        do {
            let stops = try await source.fetchStops(route: route.name, agency: route.agencyId, direction: direction)
            guard !stops.isEmpty else { return nil }
            stopsByKey[file] = stops
            writeCache(stops, file: file)
            return stops
        } catch {
            Self.logger.warning("Stops for \(route.name) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Bundled fallback

    /// Route lists built from the bundled lookups.
    static func bundledRouteLists() -> [TransportMode: [TransitRoute]] {
        makeRouteLists(
            routeLookup: BundleLoader.loadStringLookup(resource: "route_lookup"),
            headsigns: BundleLoader.loadStringLookup(resource: "headsign_lookup")
        )
    }

    /// Builds one route per (agency prefix, short name) from route_lookup
    /// ("5249_119681" -> "39A"). headsign_lookup is keyed by name only
    /// ("39A_0"), so same-named routes share headsigns here.
    static func makeRouteLists(
        routeLookup: [String: String],
        headsigns: [String: String]
    ) -> [TransportMode: [TransitRoute]] {
        var seen: Set<String> = []
        var byMode: [TransportMode: [TransitRoute]] = [:]
        for (rawId, name) in routeLookup where !name.isEmpty {
            let agencyId = TransportMode.agencyId(fromRawRouteId: rawId) ?? ""
            guard seen.insert("\(agencyId)|\(name)").inserted else { continue }
            let route = TransitRoute(
                name: name,
                agencyId: agencyId,
                headsignOutbound: headsigns["\(name)_0"],
                headsignInbound: headsigns["\(name)_1"]
            )
            byMode[TransportMode.from(rawRouteId: rawId), default: []].append(route)
        }
        return byMode.mapValues { routes in
            routes.sorted { ($0.name, $0.agencyId) < ($1.name, $1.agencyId) }
        }
    }

    // MARK: - Disk cache

    private struct CacheEntry<Value: Codable>: Codable {
        let fetchedAt: Date
        let value: Value
    }

    private func isFresh(_ fetchedAt: Date) -> Bool {
        let age = now().timeIntervalSince(fetchedAt)
        return age >= 0 && age < Self.maxAge
    }

    private func readCache<Value: Codable>(_ type: Value.Type, file: String) -> CacheEntry<Value>? {
        guard let url = cacheDirectory?.appendingPathComponent(file),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(CacheEntry<Value>.self, from: data)
    }

    private func writeCache<Value: Codable>(_ value: Value, file: String) {
        guard let directory = cacheDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(CacheEntry(fetchedAt: now(), value: value))
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        } catch {
            Self.logger.warning("Could not write cache \(file): \(error.localizedDescription)")
        }
    }

    static func routesFile(_ mode: TransportMode) -> String {
        "routes-\(mode.rawValue).json"
    }

    static func stopsFile(_ route: RouteRef, _ direction: Int) -> String {
        "stops-\(fileSafe(route.agencyId ?? "default"))-\(fileSafe(route.name))-\(direction).json"
    }

    private static func fileSafe(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
    }
}
