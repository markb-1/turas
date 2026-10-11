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
    case route(RouteRef)
    case routeAndDirection(RouteRef, direction: Int)

    var route: RouteRef? {
        switch self {
        case .idle:
            return nil
        case .route(let route), .routeAndDirection(let route, _):
            return route
        }
    }

    var routeName: String? { route?.name }

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

    /// Route lists per mode: bundled data at first, replaced by the server's
    /// (via StaticDataStore) once loaded.
    @Published private(set) var routesByMode: [TransportMode: [TransitRoute]]

    // Nearby stops (idle state — no route selected)
    @Published private(set) var nearbyStops: [NearbyStop] = []

    // Closest stop to user's location
    @Published private(set) var closestStop: RouteStop?
    @Published private(set) var walkingMinutes: Int?

    /// Single sheet state — avoids SwiftUI two-sheet conflict.
    @Published var activeSheet: SheetContent?

    var selectedRoute: RouteRef? { selection.route }
    var selectedRouteName: String? { selection.routeName }
    var selectedDirection: Int? { selection.direction }

    /// The selected route's entry in the route list, if it has one.
    var selectedTransitRoute: TransitRoute? {
        guard let route = selection.route else { return nil }
        return Self.transitRoute(for: route, in: routesByMode[selectedMode] ?? [])
    }

    /// Vehicles to display — only shown when a route is selected.
    var displayedVehicles: [Vehicle] {
        guard let route = selection.route else { return [] }
        let onRoute = vehicles.filter {
            $0.mode == selectedMode && route.matches(routeId: $0.routeId, agencyId: $0.agencyId)
        }
        guard let direction = selection.direction else { return onRoute }
        return onRoute.filter { $0.direction == direction }
    }

    /// Routes for the selected mode matching the search text
    /// (case-insensitive), sorted by name then agency. Live vehicles on
    /// routes the list does not know stay discoverable.
    var availableRoutes: [TransitRoute] {
        var routes = routesByMode[selectedMode] ?? []
        let known = Set(routes.map(\.name))
        var extra: [String: TransitRoute] = [:]
        for vehicle in vehicles where vehicle.mode == selectedMode && !known.contains(vehicle.routeId) {
            extra[vehicle.routeId] = TransitRoute(name: vehicle.routeId, agencyId: vehicle.agencyId ?? "")
        }
        if !extra.isEmpty {
            routes = (routes + extra.values).sorted { ($0.name, $0.agencyId) < ($1.name, $1.agencyId) }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return routes }
        return routes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Whether more than one agency runs a route with this name in the
    /// selected mode, so the operator must be shown alongside the name.
    func isAmbiguous(_ name: String) -> Bool {
        (routesByMode[selectedMode] ?? []).filter { $0.name == name }.count > 1
    }

    /// Route-aware color — uses Luas line-specific colours when applicable.
    var activeRouteColor: Color {
        selectedMode.routeColor(for: selection.routeName ?? "")
    }

    /// The current selection as a recent/starred entry.
    var selectionAsSavedRoute: SavedRoute? {
        guard let route = selection.route else { return nil }
        return SavedRoute(
            mode: selectedMode,
            route: route,
            direction: selection.direction,
            agencyName: isAmbiguous(route.name) ? selectedTransitRoute?.operatorLabel : nil
        )
    }

    // MARK: - Services

    let favourites: FavouritesStore
    private let serverService: TurasServerService
    private let locationService: LocationService
    private let routeShapeService: RouteShapeService
    private let routeStopService: RouteStopService
    private let staticData: StaticDataStore
    /// Bundled headsigns keyed "name_direction", for routes the list lacks.
    private let headsignLookup: [String: String]

    /// All shapes for the selected route (both directions).
    private var routeShapes: [RouteShape] = []
    private var pollingTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var nearbyTask: Task<Void, Never>?
    private var routeListsTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var hasAppeared = false

    private static let logger = Logger(subsystem: "com.turas", category: "MapViewModel")

    /// Dublin city centre — O'Connell Bridge
    static let dublinRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    private static let pollingInterval: Duration = .seconds(30)
    private static let userZoomSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)

    /// Radius for nearby stops in idle state (metres)
    private static let nearbyRadius: Double = 500

    init(
        serverService: TurasServerService,
        locationService: LocationService,
        routeShapeService: RouteShapeService,
        routeStopService: RouteStopService,
        staticData: StaticDataStore,
        favourites: FavouritesStore
    ) {
        self.serverService = serverService
        self.locationService = locationService
        self.routeShapeService = routeShapeService
        self.routeStopService = routeStopService
        self.staticData = staticData
        self.favourites = favourites
        self.headsignLookup = BundleLoader.loadStringLookup(resource: "headsign_lookup")
        // Bundled lists (small) so search works before the store answers.
        self.routesByMode = StaticDataStore.bundledRouteLists()
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

        refreshRouteLists()

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

    /// Loads the cached or bundled route lists, then refreshes any list
    /// whose cache is older than 7 days from the server. Cheap when the
    /// cache is fresh, so it also runs each time the app becomes active
    /// (e.g. after a launch while the server was still starting).
    private func refreshRouteLists() {
        guard routeListsTask == nil else { return }
        routeListsTask = Task { [weak self, store = staticData] in
            for mode in TransportMode.allCases {
                let routes = await store.routes(for: mode)
                self?.routesByMode[mode] = routes
            }
            let changed = await store.refreshRoutesIfStale()
            for mode in changed {
                let routes = await store.routes(for: mode)
                self?.routesByMode[mode] = routes
            }
            self?.refreshDirectionOptions()
            self?.routeListsTask = nil
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
            if hasAppeared {
                refreshRouteLists()
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
    /// direction picker, start polling. With a direction (from a recent or
    /// starred entry) it goes straight to step 2.
    func selectRoute(_ route: RouteRef, direction: Int? = nil) {
        resolveTask?.cancel()
        resolveTask = nil
        if let direction {
            selection = .routeAndDirection(route, direction: direction)
        } else {
            selection = .route(route)
        }
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
        recordSelection()
    }

    func selectRoute(_ route: TransitRoute) {
        selectRoute(route.ref)
    }

    /// Selects a recent or starred entry, switching mode if needed.
    func selectSaved(_ entry: SavedRoute) {
        if entry.mode != selectedMode {
            selectMode(entry.mode)
        }
        selectRoute(entry.route, direction: entry.direction)
    }

    /// Selects a route by name from a stop's route list. When two agencies
    /// share the name, the one serving the stop is chosen.
    func selectRoute(named name: String, atStop stopId: String) {
        let mode = selectedMode
        resolveTask?.cancel()
        resolveTask = Task { [weak self, store = staticData] in
            let route = await store.resolve(name: name, mode: mode, atStop: stopId)
            // A newer selection or a mode switch cancels this one.
            guard !Task.isCancelled, let self, self.selectedMode == mode else { return }
            self.selectRoute(route)
        }
    }

    /// Step 2: User picks a direction — filter to that direction, show stops.
    func selectDirection(_ direction: Int) {
        guard let route = selection.route else { return }
        selection = .routeAndDirection(route, direction: direction)
        activeRouteShapes = routeShapes.filter { $0.direction == direction }
        activeRouteStops = []
        loadDetails(for: selection)
        recordSelection()
    }

    /// Go back from direction to direction picker.
    func clearDirection() {
        guard let route = selection.route else { return }
        selection = .route(route)
        activeRouteStops = []
        closestStop = nil
        walkingMinutes = nil
        activeRouteShapes = routeShapes
        loadDetails(for: selection)
    }

    /// Clear everything back to idle — stops polling and shows nearby stops.
    func clearSearch() {
        resolveTask?.cancel()
        resolveTask = nil
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

    // MARK: - Recents & favourites

    func toggleStarForSelection() {
        guard let entry = selectionAsSavedRoute else { return }
        favourites.toggleStar(entry)
    }

    private func recordSelection() {
        guard let entry = selectionAsSavedRoute else { return }
        favourites.recordSelection(entry)
    }

    /// The user pressed Done or return in the search field. Selects the
    /// route the text identifies (so "39a" selects "39A"); otherwise stays in
    /// search, which includes a name two agencies share. An empty field just
    /// closes search.
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
    /// name match, else the only route whose name contains it. Nil when
    /// ambiguous, including one name under two agencies.
    nonisolated static func uniqueMatch(for text: String, in routes: [TransitRoute]) -> TransitRoute? {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        let exact = routes.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 {
            return exact[0]
        }
        guard exact.isEmpty else { return nil }
        let partial = routes.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// The list entry for a route: an exact (name, agency) match, else the
    /// only entry with that name.
    nonisolated static func transitRoute(for route: RouteRef, in routes: [TransitRoute]) -> TransitRoute? {
        let named = routes.filter { $0.name == route.name }
        if let agencyId = route.agencyId {
            return named.first { $0.agencyId == agencyId }
        }
        return named.count == 1 ? named[0] : nil
    }

    /// Direction choices for a route: every direction that has a shape or
    /// stops (routes 447 and 448, for example, have stops but no shapes),
    /// labelled with the headsign when one is known. A route nothing is known
    /// about (newer than the bundle, from a server that sends no directions)
    /// offers both, so the picker is never a dead end.
    nonisolated static func directionOptions(
        shapeDirections: Set<Int>,
        stopDirections: Set<Int>,
        headsign: (Int) -> String?
    ) -> [DirectionOption] {
        let known = shapeDirections.union(stopDirections)
        return (known.isEmpty ? [0, 1] : known.sorted()).map {
            DirectionOption(direction: $0, headsign: headsign($0))
        }
    }

    /// Headsign for a direction: the server's route list first, then the
    /// bundled lookup.
    private func headsign(for route: RouteRef, direction: Int) -> String? {
        if let headsign = Self.transitRoute(for: route, in: routesByMode[selectedMode] ?? [])?.headsign(for: direction) {
            return headsign
        }
        return headsignLookup["\(route.name)_\(direction)"]
    }

    /// Bundled shape and stop directions for the selected route, kept so
    /// the options can be rebuilt when the server's route list arrives.
    private var bundledDirections: Set<Int> = []

    /// Rebuilds the direction picker from the bundled directions and the
    /// route list's own directions and headsigns.
    private func refreshDirectionOptions() {
        guard let route = selection.route else { return }
        let listed = Set(selectedTransitRoute?.directions ?? [])
        let headsigns = [0: headsign(for: route, direction: 0), 1: headsign(for: route, direction: 1)]
        directionOptions = Self.directionOptions(
            shapeDirections: bundledDirections,
            stopDirections: listed,
            headsign: { headsigns[$0] ?? nil }
        )
    }

    // MARK: - Route details

    /// Loads shapes, direction options and (with a direction) stops for a
    /// selection off the main thread, then applies them if the selection
    /// has not changed meanwhile. Stops come from StaticDataStore (server,
    /// cache or bundled); shapes are bundled and keyed by name.
    private func loadDetails(for selection: RouteSelection) {
        detailsTask?.cancel()
        guard let route = selection.route else { return }

        detailsTask = Task { [weak self, shapeService = routeShapeService, stopService = routeStopService, store = staticData] in
            let shapes = await shapeService.shapes(for: route.name)
            let stopDirections = await stopService.directions(for: route.name)
            var stops: [RouteStop] = []
            if let direction = selection.direction {
                stops = await store.stops(for: route, direction: direction)
            }

            guard let self, !Task.isCancelled, self.selection == selection else { return }
            self.routeShapes = shapes
            self.bundledDirections = Set(shapes.map(\.direction)).union(stopDirections)
            self.refreshDirectionOptions()
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
        let routeNames = Set((routesByMode[mode] ?? []).map(\.name))
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

        walkingMinutes = GeoUtils.walkingMinutes(metres: minDistance)
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
        // A cancelled poll must not clear the spinner of the poll replacing it.
        defer { if !Task.isCancelled { isLoading = false } }

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
        ServerErrorText.isCancellation(error)
    }

    /// Maps technical errors to user-friendly messages.
    nonisolated static func userFriendlyError(_ error: Error) -> String {
        ServerErrorText.message(for: error)
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
