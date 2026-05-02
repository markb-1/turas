import Foundation
import MapKit
import os
import SwiftUI

/// Drives the main map screen — manages vehicle positions, polling, and map camera.
///
/// Selection state machine:
/// 1. No route (idle): searchText empty → show nearby stops, NO polling
/// 2. Route selected, no direction: searchText set → start polling, show vehicles + direction picker
/// 3. Route + direction selected: selectedDirection set → filter to direction, show stops
/// 4. Route cleared: back to idle → stop polling, show nearby stops
@MainActor
final class MapViewModel: ObservableObject {
    // MARK: - Published state

    @Published var vehicles: [Vehicle] = []
    @Published var cameraPosition: MapCameraPosition = .region(MapViewModel.dublinRegion)
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Search & filter state
    @Published var selectedMode: TransportMode = .bus
    @Published var searchText: String = ""
    @Published var isSearchActive: Bool = false
    @Published var selectedDirection: Int?
    @Published var activeRouteShapes: [RouteShape] = []
    @Published var activeRouteStops: [RouteStop] = []

    // Nearby stops (idle state — no route selected)
    @Published var nearbyStops: [NearbyStop] = []

    // Closest stop to user's location
    @Published var closestStop: RouteStop?
    @Published var walkingMinutes: Int?

    /// Single sheet state — avoids SwiftUI two-sheet conflict.
    @Published var activeSheet: SheetContent?

    /// Vehicles to display — only shown when a route is selected.
    var displayedVehicles: [Vehicle] {
        guard !searchText.isEmpty else { return [] }
        let routeFiltered = vehicles.filter { $0.mode == selectedMode && $0.routeId == searchText }
        guard let dir = selectedDirection else { return routeFiltered }
        return routeFiltered.filter { $0.direction == dir }
    }

    /// Unique route IDs for the selected mode, filtered by search text.
    /// Merges live vehicle routes with static route data so routes are
    /// always discoverable even without active vehicles in the feed.
    var availableRoutes: [String] {
        var routes = Set(vehicles.filter { $0.mode == selectedMode }.map(\.routeId))
        if let staticRoutes = staticRoutesByMode[selectedMode] {
            routes.formUnion(staticRoutes)
        }
        let sorted = routes.sorted()
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    /// Route-aware color — uses Luas line-specific colours when applicable.
    var activeRouteColor: Color {
        selectedMode.routeColor(for: searchText)
    }

    /// Live vehicle positions keyed by trip_id (for distance-based ETA + ghost detection).
    var liveVehiclePositions: [String: (lat: Double, lon: Double, direction: Int, routeId: String)] {
        var dict: [String: (lat: Double, lon: Double, direction: Int, routeId: String)] = [:]
        for v in vehicles {
            dict[v.tripId] = (v.coordinate.latitude, v.coordinate.longitude, v.direction, v.routeId)
        }
        return dict
    }

    /// Destination names for each direction of the selected route.
    var directionLabels: [(direction: Int, label: String)] {
        guard !searchText.isEmpty else { return [] }
        let shapes = routeShapeService.shapes(for: searchText)
        let directions = Set(shapes.map(\.direction)).sorted()
        return directions.compactMap { dir in
            guard let label = headsignLookup["\(searchText)_\(dir)"] else { return nil }
            return (direction: dir, label: label)
        }
    }

    // MARK: - Services

    private let serverService: TurasServerService
    private let locationService: LocationService
    private let routeShapeService: RouteShapeService
    private let routeStopService: RouteStopService
    private let headsignLookup: [String: String]
    /// All known route short names grouped by mode (from static route_lookup.json).
    private let staticRoutesByMode: [TransportMode: Set<String>]
    private var pollingTask: Task<Void, Never>?

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

    func onAppear() {
        // Resume polling only if a route was selected (e.g. returning from background)
        if !searchText.isEmpty {
            startPolling()
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

    func onDisappear() {
        stopPolling()
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

    /// Step 1: User picks a route — show both direction polylines, present direction picker.
    /// Starts polling for vehicle positions.
    func selectRoute(_ route: String) {
        searchText = route
        isSearchActive = false
        selectedDirection = nil
        activeRouteStops = []
        nearbyStops = []
        activeRouteShapes = routeShapeService.shapes(for: route)
        startPolling()
    }

    /// Step 2: User picks a direction — filter to that direction, show stops.
    func selectDirection(_ direction: Int) {
        selectedDirection = direction
        activeRouteShapes = routeShapeService.shapes(for: searchText)
            .filter { $0.direction == direction }
        activeRouteStops = routeStopService.stops(for: searchText, direction: direction)
        updateClosestStop()
    }

    /// Go back from direction to direction picker.
    func clearDirection() {
        selectedDirection = nil
        activeRouteStops = []
        closestStop = nil
        walkingMinutes = nil
        activeRouteShapes = routeShapeService.shapes(for: searchText)
    }

    /// Clear everything back to idle — stops polling and shows nearby stops.
    func clearSearch() {
        searchText = ""
        isSearchActive = false
        selectedDirection = nil
        activeRouteShapes = []
        activeRouteStops = []
        closestStop = nil
        walkingMinutes = nil
        stopPolling()
        vehicles = []
        updateNearbyStops()
    }

    // MARK: - Nearby stops (idle state)

    /// Updates nearby stops for the current mode and user location.
    /// Only runs in idle state (no route selected).
    private func updateNearbyStops() {
        guard searchText.isEmpty,
              let userCoord = locationService.userLocation else {
            nearbyStops = []
            return
        }
        nearbyStops = routeStopService.nearbyStops(
            routeNames: staticRoutesByMode[selectedMode] ?? [],
            center: userCoord,
            radius: Self.nearbyRadius
        )
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
            guard let self else { return }

            await self.fetchVehicles()

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollingInterval)
                guard !Task.isCancelled else { break }
                await self.fetchVehicles()
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

        do {
            let result = try await serverService.fetchVehicles(mode: selectedMode)
            if !result.isEmpty {
                vehicles = result
                errorMessage = nil
            }
        } catch {
            Self.logger.error("Vehicle fetch failed: \(error.localizedDescription)")
            if vehicles.isEmpty {
                errorMessage = Self.userFriendlyError(error)
            }
        }

        isLoading = false
    }

    /// Maps technical errors to user-friendly messages.
    private static func userFriendlyError(_ error: Error) -> String {
        if let serverError = error as? TurasServerError {
            switch serverError {
            case .httpError(let code):
                if code >= 500 { return "Service temporarily unavailable. Retrying..." }
                if code == 401 || code == 403 { return "API key issue. Check configuration." }
                return "Network error (\(code)). Check your connection."
            default:
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
