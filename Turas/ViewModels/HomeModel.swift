import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI

/// The home screen: which panel is showing, the mode, the map camera and
/// the user's location. Rows, search results and route focus live in the
/// child models; this one wires the transitions between them.
///
/// The timeline follows the map: the view reports where the camera
/// settled and `NearbyModel` fetches for it. Opening route focus pauses
/// the timeline and moves the camera to the route; closing it puts the
/// camera back on the place the rows were fetched for, so the rows and
/// scroll position stay intact and the resumed fetch matches the map.
@MainActor
final class HomeModel: ObservableObject {
    enum Screen: Equatable {
        case timeline
        case search
        case focus(RouteFocusTarget)
    }

    enum LocationState: Equatable {
        /// Authorisation not determined: the priming card is showing.
        case undecided
        /// Following the user's location.
        case located
        /// Not now, denied or restricted: the map started at O'Connell Bridge.
        case cityCentre
        /// Authorisation was taken away while running; the map stays put.
        case off
    }

    typealias FocusFactory = @MainActor (RouteFocusTarget, CLLocationCoordinate2D, CLLocationCoordinate2D?) -> RouteFocusModel
    /// Re-fetches stale route lists (StaticDataStore.refreshRoutesIfStale).
    typealias RouteRefresh = @Sendable () async -> Void

    /// O'Connell Bridge.
    static let cityCentre = CLLocationCoordinate2D(latitude: 53.3472, longitude: -6.2592)
    static let homeSpan = MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)

    @Published private(set) var screen: Screen = .timeline
    @Published private(set) var mode: TransportMode = .bus
    @Published var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(center: HomeModel.cityCentre, span: HomeModel.homeSpan))
    @Published private(set) var locationState: LocationState = .undecided
    /// Where the camera last settled.
    @Published private(set) var centre: CLLocationCoordinate2D = HomeModel.cityCentre
    @Published private(set) var focus: RouteFocusModel?
    /// A row id the timeline should scroll to (a pin was tapped); the view
    /// clears it after scrolling.
    @Published var scrollToRow: String?

    let nearby: NearbyModel
    let search: SearchModel

    private let location: LocationProviding
    private let makeFocus: FocusFactory
    private let refreshRoutes: RouteRefresh?
    private var routeRefreshTask: Task<Void, Never>?
    /// The span the camera last settled at, when the view reports it. Once
    /// the user moves the map, `cameraPosition` no longer holds a region.
    private var settledSpan: MKCoordinateSpan?
    /// Where closing route focus puts the camera.
    private var timelineRegion: MKCoordinateRegion?
    private var hasAppeared = false
    private var isLocating = false
    private var cancellables: Set<AnyCancellable> = []
    private var focusCancellable: AnyCancellable?

    init(nearby: NearbyModel, search: SearchModel, location: LocationProviding, refreshRoutes: RouteRefresh? = nil, makeFocus: @escaping FocusFactory) {
        self.nearby = nearby
        self.search = search
        self.location = location
        self.makeFocus = makeFocus
        self.refreshRoutes = refreshRoutes
        // Views observe this model; forward the children's changes.
        nearby.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        search.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        location.authorizationStatusPublisher
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in self?.authorizationChanged(to: status) }
            .store(in: &cancellables)
    }

    /// Only while iOS has not been asked: an authorised user waiting for
    /// the first fix never sees it.
    var showsPrimingCard: Bool {
        locationState == .undecided && location.authorizationStatus == .notDetermined && screen == .timeline
    }

    var locationNote: String? {
        switch locationState {
        case .cityCentre: return "Showing city centre"
        case .off: return "Location is off"
        case .undecided, .located: return nil
        }
    }

    /// Whether the near-me button can do anything (when undecided, it
    /// shows the iOS prompt).
    var canLocate: Bool {
        switch location.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    var userLocation: CLLocationCoordinate2D? { location.userLocation }

    /// A route-list refresh is running.
    var isRefreshingRoutes: Bool { routeRefreshTask != nil }

    // MARK: - Lifecycle

    func onAppear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        refreshRouteListsIfStale()
        switch location.authorizationStatus {
        case .notDetermined:
            locationState = .undecided
        case .authorizedWhenInUse, .authorizedAlways:
            Task { await locate(movingCamera: true) }
        default:
            locationState = .cityCentre
        }
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        if phase == .active {
            refreshRouteListsIfStale()
        }
        focus?.scenePhaseChanged(to: phase)
        if case .focus = screen {
            return // The timeline stays paused while focus is open.
        }
        nearby.scenePhaseChanged(to: phase)
    }

    /// Route lists older than 7 days are re-fetched at launch and when the
    /// app comes back, one refresh at a time.
    private func refreshRouteListsIfStale() {
        guard let refreshRoutes, routeRefreshTask == nil else { return }
        routeRefreshTask = Task { [weak self] in
            await refreshRoutes()
            self?.routeRefreshTask = nil
        }
    }

    /// The map camera stopped moving. In route focus the camera follows the
    /// route, not the user, so the timeline is left alone.
    func mapCameraSettled(centre: CLLocationCoordinate2D, span: MKCoordinateSpan? = nil) {
        self.centre = centre
        if case .focus = screen { return }
        if let span {
            settledSpan = span
        }
        nearby.cameraSettled(at: centre)
    }

    // MARK: - Location

    /// "Allow location" on the priming card: shows the iOS prompt.
    func allowLocation() {
        Task { await locate(movingCamera: true) }
    }

    /// "Not now" on the priming card.
    func notNow() {
        locationState = .cityCentre
        cameraPosition = .region(MKCoordinateRegion(center: Self.cityCentre, span: Self.homeSpan))
    }

    /// The near-me button: back to the user's location (asking first if
    /// authorisation is still undecided).
    func goNearMe() {
        Task { await locate(movingCamera: true) }
    }

    /// Asks for a fix. Without one, a first answer falls back to the city
    /// centre; any other state keeps the map where it is.
    private func locate(movingCamera: Bool) async {
        isLocating = true
        defer { isLocating = false }
        let wasUndecided = locationState == .undecided
        if let coordinate = await location.requestLocation() {
            locationState = .located
            if movingCamera {
                cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: Self.homeSpan))
            }
        } else if wasUndecided || locationState == .undecided {
            locationState = .cityCentre
            cameraPosition = .region(MKCoordinateRegion(center: Self.cityCentre, span: Self.homeSpan))
        }
    }

    /// Settings changes and "Allow Once" expiring arrive here while the app
    /// runs. The map never jumps: the timeline keeps following it.
    private func authorizationChanged(to status: CLAuthorizationStatus) {
        objectWillChange.send() // canLocate and showsPrimingCard read the status
        switch status {
        case .denied, .restricted:
            locationState = locationState == .undecided ? .cityCentre : .off
        case .notDetermined:
            if locationState == .located {
                locationState = .off
            }
        case .authorizedWhenInUse, .authorizedAlways:
            // Turned back on in Settings: refresh the fix, leave the map.
            // (A prompt answered from allowLocation or goNearMe is handled there.)
            if (locationState == .off || locationState == .cityCentre), !isLocating {
                Task { await locate(movingCamera: false) }
            }
        @unknown default:
            break
        }
    }

    // MARK: - Modes

    func selectMode(_ mode: TransportMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        nearby.setMode(mode)
        search.setMode(mode)
    }

    // MARK: - Search

    /// The search field took focus. It shows in every state, so from route
    /// focus the timeline comes back first and search opens over it.
    func beginSearch() {
        switch screen {
        case .timeline:
            break
        case .focus:
            closeFocus()
        case .search:
            return
        }
        screen = .search
    }

    func cancelSearch() {
        search.clear()
        if screen == .search {
            screen = .timeline
        }
    }

    /// A stop result: fly there; the timeline then follows the map.
    func selectStopResult(_ stop: StopSearchResult) {
        fly(to: stop.coordinate)
    }

    func selectPlaceResult(_ place: PlaceResult) {
        fly(to: place.coordinate)
    }

    /// A route result: focus, outbound, at the stop nearest the map centre.
    func selectRouteResult(_ route: RouteSearchResult) {
        search.clear()
        openFocus(RouteFocusTarget(route: route.ref, mode: route.mode, direction: 0, headsign: route.headsign(for: 0), stop: nil))
    }

    private func fly(to coordinate: CLLocationCoordinate2D) {
        search.clear()
        screen = .timeline
        cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: Self.homeSpan))
    }

    // MARK: - Route focus

    /// A timeline row: focus on its route, direction and stop.
    func openFocus(departure: NearbyDeparture) {
        let stop = nearby.result?.stop(withId: departure.stopId).map(FocusStop.init)
        openFocus(RouteFocusTarget(route: departure.routeRef, mode: mode, direction: departure.direction, headsign: departure.headsign, stop: stop))
    }

    private func openFocus(_ target: RouteFocusTarget) {
        if let focus {
            // Replacing a focus: the saved timeline camera still stands.
            focus.stop()
        } else {
            // The place the rows are for, so closing resumes a fetch for
            // the place the map shows.
            let span = settledSpan ?? cameraPosition.region?.span ?? Self.homeSpan
            timelineRegion = MKCoordinateRegion(center: nearby.fetchedCentre ?? centre, span: span)
            nearby.pause()
        }
        let model = makeFocus(target, centre, location.userLocation)
        focusCancellable = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        focus = model
        screen = .focus(target)
        Task { [weak self] in
            await model.start()
            guard let self, self.focus === model, let region = model.focusRegion else { return }
            self.cameraPosition = .region(region)
        }
    }

    /// Back chevron or swipe down: the timeline, as it was.
    func closeFocus() {
        guard let focus else { return }
        focus.stop()
        focusCancellable = nil
        self.focus = nil
        screen = .timeline
        nearby.resume()
        if let timelineRegion {
            cameraPosition = .region(timelineRegion)
            // A no-op when the rows are for this place; otherwise (focus
            // opened before the first fetch) the timeline fetches here.
            nearby.cameraSettled(at: timelineRegion.center)
        }
        timelineRegion = nil
    }

    // MARK: - Pins

    /// Tapping a pin scrolls the timeline to that stop's first row.
    func selectPin(stopId: String) {
        guard let row = nearby.firstRow(atStop: stopId) else { return }
        scrollToRow = row.id
    }
}
