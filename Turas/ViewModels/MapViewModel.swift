import Foundation
import MapKit
import os
import SwiftUI

/// What the user has selected on the map. This is the single source of
/// truth for the screen's state; `searchText` only backs the text field.
///
/// - `idle`: no route. Nearby stops are shown and nothing is polled.
/// - `route`: a route is chosen. Vehicles are polled, both directions'
///   shapes are drawn and the direction picker is shown.
/// - `routeAndDirection`: vehicles, the shape and the stops are filtered to
///   one direction.
enum RouteSelection: Equatable {
    case idle
    case route(String)
    case routeAndDirection(String, direction: Int)

    var routeName: String? {
        switch self {
        case .idle:
            return nil
        case .route(let name), .routeAndDirection(let name, _):
            return name
        }
    }

    var direction: Int? {
        if case .routeAndDirection(_, let direction) = self {
            return direction
        }
        return nil
    }
}

/// One choice in the direction picker. Routes without a headsign still get
/// an entry ("Direction 0") so they are never a dead end.
struct DirectionOption: Identifiable, Equatable {
    let direction: Int
    let headsign: String?

    var id: Int { direction }

    var title: String {
        if let headsign, !headsign.isEmpty {
            return "To \(headsign)"
        }
        return "Direction \(direction)"
    }
}

/// Drives the main map screen: selection state, vehicle polling and the
/// map camera.
@MainActor
final class MapViewModel: ObservableObject {
    // MARK: - Published state

    @Published var vehicles: [Vehicle] = []
    @Published var cameraPosition: MapCameraPosition = .region(MapViewModel.dublinRegion)
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Search & filter state
    @Published private(set) var selection: RouteSelection = .idle
    @Published private(set) var selectedMode: TransportMode = .bus
    /// Text typed into the search field. Not the selection: see `selection`.
    @Published var searchText: String = ""
    @Published var isSearchActive: Bool = false
    @Published private(set) var directionOptions: [DirectionOption] = []
    @Published private(set) var activeRouteShapes: [RouteShape] = []
    @Published private(set) var activeRouteStops: [RouteStop] = []

    // Nearby stops (idle state — no route selected)
    @Published private(set) var nearbyStops: [NearbyStop] = []

    // Closest stop to user's location
    @Published private(set) var closestStop: RouteStop?
    @Published private(set) var walkingMinutes: Int?

    /// Single sheet state — avoids SwiftUI two-sheet conflict.
    @Published var activeSheet: SheetContent?

    var selectedRouteName: String? { selection.routeName }
    var selectedDirection: Int? { selection.direction }

    /// Vehicles to display — only shown when a route is selected.
    var displayedVehicles: [Vehicle] {
        guard let routeName = selection.routeName else { return [] }
        let onRoute = vehicles.filter { $0.mode == selectedMode && $0.routeId == routeName }
        guard let direction = selection.direction else { return onRoute }
        return onRoute.filter { $0.direction == direction }
    }

    /// Route names for the selected mode matching the search text
    /// (case-insensitive). Merges live vehicle routes with the static route
    /// list so routes are discoverable without vehicles in the feed.
    var availableRoutes: [String] {
        var routes = Set(vehicles.filter { $0.mode == selectedMode }.map(\.routeId))
        if let staticRoutes = staticRoutesByMode[selectedMode] {
            routes.formUnion(staticRoutes)
        }
        let sorted = routes.sorted()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Route-aware color — uses Luas line-specific colours when applicable.
    var activeRouteColor: Color {
        selectedMode.routeColor(for: selection.routeName ?? "")
    }

    // MARK: - Services

    private let serverService: TurasServerService
    private let locationService: LocationService
    private let routeShapeService: RouteShapeService
    private let routeStopService: RouteStopService
    private let headsignLookup: [String: String]
    /// All known route short names grouped by mode (from static route_lookup.json).
    private let staticRoutesByMode: [TransportMode: Set<String>]

    /// All shapes for the selected route (both directions).
    private var routeShapes: [RouteShape] = []
    private var pollingTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var nearbyTask: Task<Void, Never>?
    private var hasAppeared = false

    private static let logger = Logger(subsystem: "com.turas", category: "MapViewModel")

    /// Dublin city centre — O'Connell Bridge
    static let dublinRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    private static let pollingInterval: Duration = .seconds(30)
    private static let userZoomSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)

    /// Walking speed: ~5 km/h = 1.33 m/s
    private static let walkingSpeedMps: Double = 1.33

    /// Radius for nearby stops in idle state (metres)
    private static let nearbyRadius: Double = 500

    init(
        serverService: TurasServerService,
        locationService: LocationService,
        routeShapeService: RouteShapeService,
        routeStopService: RouteStopService
    ) {
        self.serverService = serverService
        self.locationService = locationService
        self.routeShapeService = routeShapeService
        self.routeStopService = routeStopService
        self.headsignLookup = BundleLoader.loadStringLookup(resource: "headsign_lookup")

        // Build static route list per mode from route_lookup.json
        let routeLookup = BundleLoader.loadStringLookup(resource: "route_lookup")
        var byMode: [TransportMode: Set<String>] = [:]
        for (rawId, shortName) in routeLookup {
            let mode = TransportMode.from(rawRouteId: rawId)
            byMode[mode, default: []].insert(shortName)
        }
        self.staticRoutesByMode = byMode
    }

    // MARK: - Lifecycle

    /// Called once when the map first appears.
    func onAppear() {
        guard !hasAppeared else { return }
        hasAppeared = true

        // Decode the bundled shapes and stops off the main thread now, so
        // the first route tap does not hitch.
        Task.detached(priority: .utility) { [shapes = routeShapeService, stops = routeStopService] in
            await shapes.preload()
            await stops.preload()
        }

        Task {
            if let location = await locationService.requestLocation() {
                cameraPosition = .region(MKCoordinateRegion(
                    center: location,
                    span: Self.userZoomSpan
                ))

                updateNearbyStops()
                updateClosestStop()
            }
        }
    }

    /// Stops polling in the background and resumes it when the app becomes
    /// active again with a route selected. The root view never disappears,
    /// so the scene phase is the only reliable signal.
    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            if selection.routeName != nil {
                startPolling()
            }
        case .background:
            stopPolling()
        default:
            break
        }
    }

    // MARK: - Sheet selection

    func selectVehicle(_ vehicle: Vehicle) {
        activeSheet = .vehicle(vehicle)
    }

    func selectStop(_ stop: RouteStop) {
        activeSheet = .stop(stop)
    }

    func selectNearbyStop(_ nearbyStop: NearbyStop) {
        activeSheet = .nearbyStop(nearbyStop)
    }

    // MARK: - Transport mode

    /// Switch transport mode — clears any active route/direction selection.
    func selectMode(_ mode: TransportMode) {
        guard mode != selectedMode else { return }
        clearSearch()
        selectedMode = mode
        updateNearbyStops()
    }

    // MARK: - Search & direction

    /// Step 1: User picks a route — show both direction polylines, present
    /// direction picker, start polling.
    func selectRoute(_ route: String) {
        selection = .route(route)
        searchText = ""
        isSearchActive = false
        routeShapes = []
        activeRouteShapes = []
        activeRouteStops = []
        directionOptions = []
        nearbyStops = []
        closestStop = nil
        walkingMinutes = nil
        startPolling()
        loadDetails(for: selection)
    }

    /// Step 2: User picks a direction — filter to that direction, show stops.
    func selectDirection(_ direction: Int) {
        guard let routeName = selection.routeName else { return }
        selection = .routeAndDirection(routeName, direction: direction)
        activeRouteShapes = routeShapes.filter { $0.direction == direction }
        activeRouteStops = []
        loadDetails(for: selection)
    }

    /// Go back from direction to direction picker.
    func clearDirection() {
        guard let routeName = selection.routeName else { return }
        selection = .route(routeName)
        activeRouteStops = []
        closestStop = nil
        walkingMinutes = nil
        activeRouteShapes = routeShapes
        loadDetails(for: selection)
    }

    /// Clear everything back to idle — stops polling and shows nearby stops.
    func clearSearch() {
        selection = .idle
        searchText = ""
        isSearchActive = false
        detailsTask?.cancel()
        detailsTask = nil
        routeShapes = []
        activeRouteShapes = []
        activeRouteStops = []
        directionOptions = []
        closestStop = nil
        walkingMinutes = nil
        stopPolling()
        vehicles = []
        errorMessage = nil
        updateNearbyStops()
    }

    /// The user pressed Done or return in the search field. Selects the
    /// route the text identifies (so "39a" selects "39A"); otherwise stays in
    /// search. An empty field just closes search.
    func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            searchText = ""
            isSearchActive = false
            return
        }
        if let match = Self.uniqueMatch(for: query, in: availableRoutes) {
            selectRoute(match)
        }
    }

    /// The single route `text` identifies: the only case-insensitive exact
    /// match, else the only route containing it. Nil when ambiguous.
    nonisolated static func uniqueMatch(for text: String, in routes: [String]) -> String? {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        let exact = routes.filter { $0.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 {
            return exact[0]
        }
        guard exact.isEmpty else { return nil }
        let partial = routes.filter { $0.localizedCaseInsensitiveContains(query) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Direction choices for a route: every direction that has a shape or
    /// stops (routes 447 and 448, for example, have stops but no shapes),
    /// labelled with the headsign when one is known.
    nonisolated static func directionOptions(
        shapeDirections: Set<Int>,
        stopDirections: Set<Int>,
        headsign: (Int) -> String?
    ) -> [DirectionOption] {
        shapeDirections.union(stopDirections).sorted().map {
            DirectionOption(direction: $0, headsign: headsign($0))
        }
    }

    // MARK: - Route details

    /// Loads shapes, direction options and (with a direction) stops for a
    /// selection off the main thread, then applies them if the selection
    /// has not changed meanwhile.
    private func loadDetails(for selection: RouteSelection) {
        detailsTask?.cancel()
        guard let routeName = selection.routeName else { return }
        let headsigns = headsignLookup

        detailsTask = Task { [weak self, shapeService = routeShapeService, stopService = routeStopService] in
            let shapes = await shapeService.shapes(for: routeName)
            let stopDirections = await stopService.directions(for: routeName)
            var stops: [RouteStop] = []
            if let direction = selection.direction {
                stops = await stopService.stops(for: routeName, direction: direction)
            }

            guard let self, !Task.isCancelled, self.selection == selection else { return }
            self.routeShapes = shapes
            self.directionOptions = Self.directionOptions(
                shapeDirections: Set(shapes.map(\.direction)),
                stopDirections: stopDirections,
                headsign: { headsigns["\(routeName)_\($0)"] }
            )
            if let direction = selection.direction {
                self.activeRouteShapes = shapes.filter { $0.direction == direction }
                self.activeRouteStops = stops
                self.updateClosestStop()
            } else {
                self.activeRouteShapes = shapes
            }
        }
    }

    // MARK: - Nearby stops (idle state)

    /// Updates nearby stops for the current mode and user location.
    /// Only runs in idle state (no route selected).
    private func updateNearbyStops() {
        nearbyTask?.cancel()
        guard selection == .idle,
              let userCoord = locationService.userLocation else {
            nearbyStops = []
            return
        }
        let mode = selectedMode
        let routeNames = staticRoutesByMode[mode] ?? []
        let latitude = userCoord.latitude
        let longitude = userCoord.longitude

        nearbyTask = Task { [weak self, stopService = routeStopService] in
            let stops = await stopService.nearbyStops(
                routeNames: routeNames,
                latitude: latitude,
                longitude: longitude,
                radius: Self.nearbyRadius
            )
            guard let self, !Task.isCancelled,
                  self.selection == .idle, self.selectedMode == mode else { return }
            self.nearbyStops = stops
        }
    }

    // MARK: - Closest stop

    /// Finds the stop nearest to the user's location and estimates walking time.
    private func updateClosestStop() {
        guard let userCoord = locationService.userLocation,
              !activeRouteStops.isEmpty else {
            closestStop = nil
            walkingMinutes = nil
            return
        }

        var nearest: RouteStop?
        var minDistance = Double.infinity

        for stop in activeRouteStops {
            let d = GeoUtils.straightLineDistance(
                lat1: userCoord.latitude, lon1: userCoord.longitude,
                lat2: stop.lat, lon2: stop.lon
            )
            if d < minDistance {
                minDistance = d
                nearest = stop
            }
        }

        closestStop = nearest

        // Walking estimate: straight-line x road factor, at walking speed
        let walkingDistance = minDistance * GeoUtils.roadFactor
        let walkingSeconds = walkingDistance / Self.walkingSpeedMps
        walkingMinutes = max(1, Int(walkingSeconds / 60))
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            await self?.fetchVehicles()

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollingInterval)
                guard !Task.isCancelled else { break }
                await self?.fetchVehicles()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func fetchVehicles() async {
        if vehicles.isEmpty {
            isLoading = true
        }
        defer { isLoading = false }

        let mode = selectedMode
        do {
            let result = try await serverService.fetchVehicles(mode: mode)
            guard mode == selectedMode, selection != .idle else { return }
            // An empty list is a real answer (no vehicles running), so it
            // replaces the previous positions instead of leaving stale ones.
            vehicles = result
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            Self.logger.error("Vehicle fetch failed: \(error.localizedDescription)")
            // Keep showing the last good positions; only an empty map gets
            // an error message.
            if vehicles.isEmpty {
                errorMessage = Self.userFriendlyError(error)
            }
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    /// Maps technical errors to user-friendly messages.
    nonisolated static func userFriendlyError(_ error: Error) -> String {
        if let serverError = error as? TurasServerError {
            switch serverError {
            case .httpError(let code):
                switch code {
                case 401, 403:
                    return "API key issue. Check configuration."
                case 429:
                    return "Too many requests. Retrying..."
                case 503:
                    return "Server is starting up. Retrying..."
                case 500...:
                    return "Service temporarily unavailable. Retrying..."
                default:
                    return "Network error (\(code)). Check your connection."
                }
            case .invalidURL, .invalidResponse:
                return "Server error. Retrying..."
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "No internet connection. Check your network."
        }
        return "Something went wrong. Retrying..."
    }
}

// MARK: - Sheet Content

/// Enum for the single-sheet pattern — avoids SwiftUI limitation
/// where two `.sheet(item:)` modifiers on the same view conflict.
enum SheetContent: Identifiable {
    case vehicle(Vehicle)
    case stop(RouteStop)
    case nearbyStop(NearbyStop)

    var id: String {
        switch self {
        case .vehicle(let v): return "vehicle-\(v.id)"
        case .stop(let s): return "stop-\(s.id)"
        case .nearbyStop(let ns): return "nearby-\(ns.id)"
        }
    }
}
