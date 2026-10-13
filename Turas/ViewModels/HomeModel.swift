import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI

/// The home screen: which panel is showing, the mode, the map camera and
/// the user's location. Rows, search results, the stop view and route
/// focus live in the child models; this one wires the transitions.
///
/// The timeline follows the map: the view reports where the camera
/// settled and `NearbyModel` fetches for it. Opening the stop view or
/// route focus pauses the timeline and saves the camera; closing the
/// last of them puts the camera back on the place the rows were fetched
/// for, so the rows and scroll position stay intact and the resumed
/// fetch matches the map. Focus opened from the stop view returns to it.
@MainActor
final class HomeModel: ObservableObject {
    enum Screen: Equatable {
        case timeline
        case search
        case stop(StopTarget)
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

    /// A pin as the map draws it.
    struct MapPin: Identifiable, Equatable {
        let target: StopTarget
        let isHighlighted: Bool

        var id: String { target.id }
    }

    typealias FocusFactory = @MainActor (RouteFocusTarget, CLLocationCoordinate2D, CLLocationCoordinate2D?) -> RouteFocusModel
    /// Makes the stop view's model for a stop and the user's location
    /// (nil without authorisation).
    typealias StopFactory = @MainActor (StopTarget, CLLocationCoordinate2D?) -> StopModel
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
    /// The stop view's model. It stays while route focus is open over the
    /// stop view, which is how closing focus knows to return there.
    @Published private(set) var stop: StopModel?

    let nearby: NearbyModel
    let search: SearchModel
    let stations: StationStore

    private let location: LocationProviding
    private let makeFocus: FocusFactory
    private let makeStop: StopFactory
    private let refreshRoutes: RouteRefresh?
    private var routeRefreshTask: Task<Void, Never>?
    /// The span the camera last settled at, when the view reports it. Once
    /// the user moves the map, `cameraPosition` no longer holds a region.
    private var settledSpan: MKCoordinateSpan?
    /// Where closing the stop view or route focus puts the camera.
    private var timelineRegion: MKCoordinateRegion?
    private var hasAppeared = false
    private var isLocating = false
    private var cancellables: Set<AnyCancellable> = []
    private var focusCancellable: AnyCancellable?
    private var stopCancellable: AnyCancellable?

    init(
        nearby: NearbyModel,
        search: SearchModel,
        stations: StationStore,
        location: LocationProviding,
        refreshRoutes: RouteRefresh? = nil,
        makeFocus: @escaping FocusFactory,
        makeStop: @escaping StopFactory
    ) {
        self.nearby = nearby
        self.search = search
        self.stations = stations
        self.location = location
        self.makeFocus = makeFocus
        self.makeStop = makeStop
        self.refreshRoutes = refreshRoutes
        // Views observe this model; forward the children's changes.
        nearby.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        search.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        stations.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        location.authorizationStatusPublisher
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in self?.authorizationChanged(to: status) }
            .store(in: &cancellables)
        // The stop view's distance follows new fixes and authorisation. The
        // publishers fire before the properties change, so use their values.
        location.userLocationPublisher
            .combineLatest(location.authorizationStatusPublisher)
            .sink { [weak self] coordinate, status in
                self?.stop?.userLocation = Self.isAuthorised(status) ? coordinate : nil
            }
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

    /// The user's location while authorised: a fix from before location
    /// was turned off is no longer where the user is.
    private var authorisedUserLocation: CLLocationCoordinate2D? {
        Self.isAuthorised(location.authorizationStatus) ? location.userLocation : nil
    }

    nonisolated private static func isAuthorised(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// A route-list refresh is running.
    var isRefreshingRoutes: Bool { routeRefreshTask != nil }

    /// The pins for the current mode: every bus stop `/nearby` returned
    /// (within 300 m of the centre), or every station of the mode once
    /// `/stations` has answered, with `/nearby`'s stops until then.
    var pins: [StopTarget] {
        if mode != .bus, let stations = stations.stations(for: mode) {
            return stations.map { StopTarget($0, mode: mode) }
        }
        return nearby.stops.map { StopTarget($0, mode: mode) }
    }

    /// The pins to draw: `pins`, with the stop view's stop highlighted and
    /// added when it is not among them (a stop result can lie outside the
    /// pins fetched for the timeline's place).
    var mapPins: [MapPin] {
        let pins = pins
        guard case .stop(let target) = screen else {
            return pins.map { MapPin(target: $0, isHighlighted: false) }
        }
        var drawn = pins.map { MapPin(target: $0, isHighlighted: $0.id == target.id) }
        if !pins.contains(where: { $0.id == target.id }) {
            drawn.append(MapPin(target: target, isHighlighted: true))
        }
        return drawn
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        refreshRouteListsIfStale()
        stations.load(mode)
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
            refreshLocation()
        }
        focus?.scenePhaseChanged(to: phase)
        stop?.scenePhaseChanged(to: phase)
        switch screen {
        case .focus, .stop:
            return // The timeline stays paused under them.
        case .timeline, .search:
            nearby.scenePhaseChanged(to: phase)
        }
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
    /// route, and in the stop view the stop, so the timeline is left alone.
    func mapCameraSettled(centre: CLLocationCoordinate2D, span: MKCoordinateSpan? = nil) {
        self.centre = centre
        if case .focus = screen { return }
        if let span {
            settledSpan = span
        }
        if case .stop = screen { return }
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

    /// Back in the foreground: a fresh fix for the stop view's distance and
    /// route focus's walking time. Never prompts, and the map stays put.
    private func refreshLocation() {
        guard Self.isAuthorised(location.authorizationStatus), !isLocating else { return }
        Task { await locate(movingCamera: false) }
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
        stations.load(mode)
    }

    // MARK: - Search

    /// The search field took focus. It shows in every state, so from route
    /// focus or the stop view the timeline comes back first and search
    /// opens over it.
    func beginSearch() {
        if case .search = screen { return }
        if case .focus = screen {
            closeFocus() // lands on the stop view when focus came from it
        }
        if case .stop = screen {
            closeStop()
        }
        screen = .search
    }

    func cancelSearch() {
        search.clear()
        if screen == .search {
            screen = .timeline
        }
    }

    /// A stop result: the stop view for that stop, as the stop's mode.
    func selectStopResult(_ stop: StopSearchResult) {
        openStop(StopTarget(stop, preferring: mode), span: Self.homeSpan)
    }

    func selectPlaceResult(_ place: PlaceResult) {
        fly(to: place.coordinate)
    }

    /// A route result: focus, outbound, at the stop nearest the map centre.
    func selectRouteResult(_ route: RouteSearchResult) {
        search.clear()
        openFocus(RouteFocusTarget(route: route.ref, mode: route.mode, direction: 0, headsign: route.headsign(for: 0), stop: nil), centre: centre)
    }

    private func fly(to coordinate: CLLocationCoordinate2D) {
        search.clear()
        screen = .timeline
        cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: Self.homeSpan))
    }

    // MARK: - Stop view

    /// A pin or a stop result: the stop view, centred on the stop at the
    /// user's zoom (or `span`). From the stop view, another stop replaces
    /// it; the same stop (ID and mode: search and pins can differ in name
    /// and coordinates) is a no-op.
    func openStop(_ target: StopTarget, span: MKCoordinateSpan? = nil) {
        if case .search = screen {
            search.clear()
        }
        let isTimelinePaused = focus != nil || stop != nil
        if focus != nil {
            // Not reachable from the map in focus; keeps the state machine
            // total. Over a stop view, close focus as back does (the same
            // stop is then a no-op, another replaces it); over the timeline,
            // the timeline stays paused with its camera saved.
            if stop != nil {
                closeFocus()
            } else {
                endFocus()
            }
        }
        if let stop {
            guard stop.target.id != target.id || stop.target.mode != target.mode else { return }
            // Replacing a stop: the saved timeline camera still stands.
            stop.stop()
            stopCancellable = nil
        } else if !isTimelinePaused {
            leaveTimeline()
        }
        let model = makeStop(target, authorisedUserLocation)
        stopCancellable = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        stop = model
        screen = .stop(target)
        cameraPosition = .region(MKCoordinateRegion(center: target.coordinate, span: span ?? settledSpan ?? Self.homeSpan))
        Task { await model.start() }
    }

    /// Back chevron or swipe down on the stop view: the timeline, as it was.
    /// Focus open over the stop view closes with it.
    func closeStop() {
        guard let stop else { return }
        endFocus()
        stop.stop()
        stopCancellable = nil
        self.stop = nil
        returnToTimeline()
    }

    // MARK: - Route focus

    /// A timeline or stop view row: focus on its route, direction and stop.
    func openFocus(departure: NearbyDeparture) {
        if let stop {
            let target = RouteFocusTarget(route: departure.routeRef, mode: stop.target.mode, direction: departure.direction,
                                          headsign: departure.headsign, stop: stop.focusStop)
            openFocus(target, centre: stop.target.coordinate)
        } else {
            let focusStop = nearby.result?.stop(withId: departure.stopId).map(FocusStop.init)
            openFocus(RouteFocusTarget(route: departure.routeRef, mode: mode, direction: departure.direction,
                                       headsign: departure.headsign, stop: focusStop), centre: centre)
        }
    }

    private func openFocus(_ target: RouteFocusTarget, centre focusCentre: CLLocationCoordinate2D) {
        if let focus {
            // Replacing a focus: whatever is saved beneath it still stands.
            focus.stop()
        } else if let stop {
            // Focus over the stop view: the stop waits, the timeline is already paused.
            stop.pause()
        } else {
            leaveTimeline()
        }
        let model = makeFocus(target, focusCentre, authorisedUserLocation)
        focusCancellable = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        focus = model
        screen = .focus(target)
        Task { [weak self] in
            await model.start()
            guard let self, self.focus === model, let region = model.focusRegion else { return }
            self.cameraPosition = .region(region)
        }
    }

    /// Back chevron or swipe down: the stop view when focus came from it,
    /// else the timeline, as it was.
    func closeFocus() {
        guard focus != nil else { return }
        endFocus()
        if let stop {
            screen = .stop(stop.target)
            cameraPosition = .region(MKCoordinateRegion(center: stop.target.coordinate, span: settledSpan ?? Self.homeSpan))
            stop.resume()
            return
        }
        returnToTimeline()
    }

    private func endFocus() {
        focus?.stop()
        focusCancellable = nil
        focus = nil
    }

    // MARK: - Timeline camera

    /// Leaving the timeline for the stop view or focus: remember the place
    /// the rows are for, so coming back resumes a fetch for the place the
    /// map shows.
    private func leaveTimeline() {
        let span = settledSpan ?? cameraPosition.region?.span ?? Self.homeSpan
        timelineRegion = MKCoordinateRegion(center: nearby.fetchedCentre ?? centre, span: span)
        nearby.pause()
    }

    private func returnToTimeline() {
        screen = .timeline
        nearby.resume()
        if let timelineRegion {
            cameraPosition = .region(timelineRegion)
            // A no-op when the rows are for this place; otherwise (opened
            // before the first fetch) the timeline fetches here.
            nearby.cameraSettled(at: timelineRegion.center)
        }
        timelineRegion = nil
    }
}
