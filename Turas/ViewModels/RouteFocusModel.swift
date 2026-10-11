import CoreLocation
import Foundation
import MapKit
import os
import SwiftUI

/// A stop to highlight in route focus: from a timeline pin, a route stop or
/// the map centre's nearest stop.
struct FocusStop: Hashable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double

    init(id: String, name: String, lat: Double, lon: Double) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
    }

    init(_ stop: DepartureStop) {
        self.init(id: stop.id, name: stop.name, lat: stop.lat, lon: stop.lon)
    }

    init(_ stop: RouteStop) {
        self.init(id: stop.id, name: stop.name, lat: stop.lat, lon: stop.lon)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// As a route stop (no sequence or offset known).
    var routeStop: RouteStop {
        RouteStop(id: id, name: name, lat: lat, lon: lon, seq: 0, t: 0)
    }
}

/// What route focus was opened for.
struct RouteFocusTarget: Hashable, Sendable {
    let route: RouteRef
    let mode: TransportMode
    let direction: Int
    /// Known from the timeline row or the search result; nil asks the
    /// route list and the bundled lookup.
    let headsign: String?
    /// The stop to highlight; nil (from a route search result) means the
    /// stop on the route nearest the map centre.
    let stop: FocusStop?
}

/// One route, direction and stop: the line (bundled shape), the stops, the
/// live vehicles on that direction and the next arrivals at the stop,
/// refreshed every 30 s while open. Flipping the direction keeps the
/// user near the same place: the nearest stop in the other direction.
@MainActor
final class RouteFocusModel: ObservableObject {
    static let refreshInterval: Duration = .seconds(30)
    /// How much of the line around the stop the camera fits, in metres.
    nonisolated static let focusRadius: Double = 800

    let route: RouteRef
    let mode: TransportMode

    @Published private(set) var direction: Int
    @Published private(set) var headsign: String?
    @Published private(set) var stops: [RouteStop] = []
    @Published private(set) var shape: RouteShape?
    @Published private(set) var highlightedStop: RouteStop?
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var arrivals: [StopArrival] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = true

    private let source: FocusSource
    private let staticData: StaticDataStore
    private let shapes: RouteShapeService
    private let clock: AppClock
    private let headsignLookup: [String: String]
    private let centre: CLLocationCoordinate2D
    private let userLocation: CLLocationCoordinate2D?
    private let target: RouteFocusTarget
    private var requestedStop: FocusStop?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    /// Between `start()` and `stop()`.
    private var isStarted = false
    /// The scene is in the foreground.
    private var isForeground = true

    private static let logger = Logger(subsystem: "com.turas", category: "RouteFocusModel")

    init(
        target: RouteFocusTarget,
        centre: CLLocationCoordinate2D,
        userLocation: CLLocationCoordinate2D?,
        source: FocusSource,
        staticData: StaticDataStore,
        shapes: RouteShapeService,
        clock: AppClock = .system,
        headsignLookup: [String: String] = BundleLoader.loadStringLookup(resource: "headsign_lookup")
    ) {
        self.target = target
        self.route = target.route
        self.mode = target.mode
        self.direction = target.direction
        self.headsign = target.headsign
        self.requestedStop = target.stop
        self.centre = centre
        self.userLocation = userLocation
        self.source = source
        self.staticData = staticData
        self.shapes = shapes
        self.clock = clock
        self.headsignLookup = headsignLookup
    }

    /// Minutes to walk from the user's location to the highlighted stop.
    var walkingMinutes: Int? {
        guard let userLocation, let stop = highlightedStop else { return nil }
        return GeoUtils.walkingMinutes(metres: Self.distance(from: userLocation, to: stop))
    }

    /// Metres from the map centre to the highlighted stop (shown when the
    /// user's location is unknown).
    var distanceFromCentre: Int? {
        guard let stop = highlightedStop else { return nil }
        return Int(Self.distance(from: centre, to: stop).rounded())
    }

    /// The camera for this focus: the stop and the nearby part of the line.
    var focusRegion: MKCoordinateRegion? {
        guard let stop = highlightedStop else { return nil }
        return Self.focusRegion(stop: stop, shape: shape)
    }

    // MARK: - Lifecycle

    /// Loads the stops and shape, picks the stop and fetches; returns once
    /// the first answer is in, leaving a 30 s refresh running.
    func start() async {
        isStarted = true
        await load()
        await refresh()
        startRefreshing(immediately: false)
    }

    func stop() {
        isStarted = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            guard !isForeground else { return }
            isForeground = true
            // Back from the background: fetch now, not 30 s later.
            startRefreshing(immediately: true)
        case .background:
            isForeground = false
            refreshTask?.cancel()
            refreshTask = nil
        default:
            break
        }
    }

    /// The ⇄ button: the other direction, at the stop nearest to the
    /// current one.
    func flipDirection() async {
        refreshTask?.cancel()
        refreshTask = nil
        let fromStop = highlightedStop
        direction = 1 - direction
        headsign = direction == target.direction ? target.headsign : nil
        requestedStop = nil
        await load(nearestTo: fromStop?.coordinate ?? centre)
        await refresh()
        startRefreshing(immediately: false)
    }

    // MARK: - Loading

    private func load(nearestTo point: CLLocationCoordinate2D? = nil) async {
        isLoading = true
        generation += 1
        let generation = generation
        let (staticData, shapes, route, mode, direction) = (staticData, shapes, route, mode, direction)
        async let loadedStops = staticData.stops(for: route, direction: direction)
        async let loadedShapes = shapes.shapes(for: route.name)
        async let listed = staticData.routes(for: mode)
        let (routeStops, routeShapes, routes) = await (loadedStops, loadedShapes, listed)
        guard generation == self.generation else { return }

        stops = routeStops
        shape = routeShapes.first { $0.direction == direction }
        highlightedStop = Self.pickStop(requested: requestedStop, in: routeStops, nearestTo: point ?? requestedStop?.coordinate ?? centre)
        if headsign == nil {
            let fromList = routes.first { $0.name == route.name && $0.agencyId == route.agencyId }?.headsign(for: direction)
            headsign = fromList ?? headsignLookup["\(route.name)_\(direction)"]
        }
        isLoading = false
    }

    /// The stop to highlight: the requested stop when the list has it, else
    /// the requested stop itself (the timeline's pin is newer than a bundled
    /// stop list), else the stop nearest to `point`.
    nonisolated static func pickStop(requested: FocusStop?, in stops: [RouteStop], nearestTo point: CLLocationCoordinate2D) -> RouteStop? {
        if let requested {
            return stops.first { $0.id == requested.id } ?? requested.routeStop
        }
        return stops.min { distance(from: point, to: $0) < distance(from: point, to: $1) }
    }

    private nonisolated static func distance(from point: CLLocationCoordinate2D, to stop: RouteStop) -> Double {
        GeoUtils.straightLineDistance(lat1: point.latitude, lon1: point.longitude, lat2: stop.lat, lon2: stop.lon)
    }

    /// A region fitting the stop and the shape points within `focusRadius`
    /// of it, padded 30%; just the stop (0.008° span) when there is no line.
    nonisolated static func focusRegion(stop: RouteStop, shape: RouteShape?) -> MKCoordinateRegion {
        let near = (shape?.clCoordinates ?? []).filter { distance(from: $0, to: stop) <= focusRadius }
        guard !near.isEmpty else {
            return MKCoordinateRegion(center: stop.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))
        }
        let points = near + [stop.coordinate]
        let latitudes = points.map(\.latitude), longitudes = points.map(\.longitude)
        let (minLat, maxLat) = (latitudes.min() ?? stop.lat, latitudes.max() ?? stop.lat)
        let (minLon, maxLon) = (longitudes.min() ?? stop.lon, longitudes.max() ?? stop.lon)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.005, (maxLat - minLat) * 1.3),
                longitudeDelta: max(0.005, (maxLon - minLon) * 1.3)
            )
        )
    }

    // MARK: - Refreshing

    /// Runs the 30 s refresh loop: refreshing first when `immediately`,
    /// else sleeping first (the caller has just refreshed).
    private func startRefreshing(immediately: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        guard isStarted, isForeground else { return }
        let clock = clock
        let interval = Self.refreshInterval
        // Weak, and strong only for one refresh: a model nobody holds ends
        // the loop at its next tick instead of being kept alive by it.
        refreshTask = Task { [weak self] in
            if !immediately {
                guard (try? await clock.sleep(interval)) != nil else { return }
            }
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    await self.refresh()
                }
                guard (try? await clock.sleep(interval)) != nil else { return }
            }
        }
    }

    /// Fetches the vehicles on this direction and the arrivals at the
    /// highlighted stop. Failures keep the last answer and set a message.
    /// Does nothing while the stops are loading (the stop may be stale).
    func refresh() async {
        guard !isLoading else { return }
        let generation = generation
        let (source, route, mode, direction, stop) = (source, route, mode, direction, highlightedStop)
        do {
            async let fetchedVehicles = Self.fetchVehicles(source: source, route: route, mode: mode, direction: direction)
            async let fetchedArrivals = Self.fetchArrivals(source: source, route: route, mode: mode, direction: direction, stop: stop)
            let (nextVehicles, nextArrivals) = try await (fetchedVehicles, fetchedArrivals)
            guard generation == self.generation else { return }
            vehicles = nextVehicles
            arrivals = nextArrivals
            lastUpdated = clock.now()
            errorMessage = nil
        } catch {
            guard generation == self.generation, !ServerErrorText.isCancellation(error) else { return }
            Self.logger.error("Focus refresh failed: \(error.localizedDescription)")
            errorMessage = ServerErrorText.message(for: error)
        }
    }

    /// The route's vehicles on `direction`. The Luas has no live positions
    /// in TFI's feed, so it is not asked.
    private nonisolated static func fetchVehicles(
        source: FocusSource, route: RouteRef, mode: TransportMode, direction: Int
    ) async throws -> [Vehicle] {
        guard mode != .luas else { return [] }
        return try await source.fetchVehicles(mode: mode).filter {
            route.matches(routeId: $0.routeId, agencyId: $0.agencyId) && $0.direction == direction
        }
    }

    private nonisolated static func fetchArrivals(
        source: FocusSource, route: RouteRef, mode: TransportMode, direction: Int, stop: RouteStop?
    ) async throws -> [StopArrival] {
        guard let stop else { return [] }
        if mode == .luas {
            return try await source.fetchLuasArrivals(stopId: stop.id, direction: direction, routeName: route.name)
        }
        return try await source.fetchArrivals(stopId: stop.id, route: route, direction: direction)
    }
}
