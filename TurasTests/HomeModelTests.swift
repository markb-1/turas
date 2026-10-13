import Combine
import CoreLocation
import MapKit
import SwiftUI
import XCTest
@testable import Turas

@MainActor
private final class FakeLocation: LocationProviding {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var userLocation: CLLocationCoordinate2D?
    /// What the user answers when the prompt is shown.
    var answer: CLAuthorizationStatus = .authorizedWhenInUse
    var fix: CLLocationCoordinate2D? = CLLocationCoordinate2D(latitude: 53.3441, longitude: -6.2595)
    private(set) var requests = 0

    var authorizationStatusPublisher: AnyPublisher<CLAuthorizationStatus, Never> {
        $authorizationStatus.eraseToAnyPublisher()
    }

    func requestLocation() async -> CLLocationCoordinate2D? {
        requests += 1
        if authorizationStatus == .notDetermined {
            authorizationStatus = answer
        }
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return nil }
        userLocation = fix
        return fix
    }
}

private actor EmptyStaticSource: StaticDataSource {
    func fetchRoutes(mode: TransportMode) async throws -> [TransitRoute] { [] }
    func fetchStops(route: String, agency: String?, direction: Int) async throws -> [RouteStop] { [] }
}

private actor NoPlaces: PlaceSearching {
    func searchPlaces(_ query: String) async throws -> [PlaceResult] { [] }
}

@MainActor
final class HomeModelTests: XCTestCase {
    private let clock = ManualClock()
    private let nearbySource = FakeNearbySource()
    private let focusSource = FakeFocusSource()
    private let location = FakeLocation()
    private let collegeGreen = CLLocationCoordinate2D(latitude: 53.3441, longitude: -6.2595)

    private func makeModel(refreshRoutes: HomeModel.RouteRefresh? = nil) -> HomeModel {
        let nearby = NearbyModel(source: nearbySource, clock: clock.appClock)
        let search = SearchModel(source: FakeSearchSource(), places: NoPlaces(), clock: clock.appClock)
        let store = StaticDataStore(source: EmptyStaticSource(), bundledStops: RouteStopService(stopsByRoute: [:]), cacheDirectory: nil, bundledRoutes: { [:] })
        let clock = clock
        let focusSource = focusSource
        return HomeModel(nearby: nearby, search: search, location: location, refreshRoutes: refreshRoutes) { target, centre, userLocation in
            RouteFocusModel(target: target, centre: centre, userLocation: userLocation, source: focusSource,
                            staticData: store, shapes: RouteShapeService(shapes: [:]), clock: clock.appClock, headsignLookup: [:])
        }
    }

    private func centre(of position: MapCameraPosition) -> CLLocationCoordinate2D? {
        position.region?.center
    }

    private func assertCentre(_ position: MapCameraPosition, is expected: CLLocationCoordinate2D, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let actual = centre(of: position)
        XCTAssertEqual(actual?.latitude ?? 0, expected.latitude, accuracy: 1e-6, message, file: file, line: line)
        XCTAssertEqual(actual?.longitude ?? 0, expected.longitude, accuracy: 1e-6, message, file: file, line: line)
    }

    /// Loads the timeline as the map view would: settle, fire the timer.
    private func loadTimeline(_ model: HomeModel) async {
        model.mapCameraSettled(centre: collegeGreen)
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 0.6)
        await waitUntil { model.nearby.result != nil }
        await waitUntil { self.clock.sleeperCount == 1 }
    }

    // MARK: - Location

    func testFirstLaunchShowsPrimingCardAtCityCentre() {
        let model = makeModel()
        model.onAppear()
        XCTAssertEqual(model.locationState, .undecided)
        XCTAssertTrue(model.showsPrimingCard)
        XCTAssertNil(model.locationNote)
        assertCentre(model.cameraPosition, is: HomeModel.cityCentre)
        XCTAssertEqual(location.requests, 0, "the iOS prompt never appears unexplained")
    }

    func testAllowLocationPromptsThenCentresOnTheUser() async {
        let model = makeModel()
        model.onAppear()
        model.allowLocation()
        await waitUntil { model.locationState == .located }
        XCTAssertEqual(location.requests, 1)
        XCTAssertFalse(model.showsPrimingCard)
        assertCentre(model.cameraPosition, is: collegeGreen)
        XCTAssertTrue(model.canLocate)
        XCTAssertEqual(model.userLocation?.latitude, collegeGreen.latitude)
    }

    func testAllowLocationButDeniedFallsBackToCityCentre() async {
        location.answer = .denied
        let model = makeModel()
        model.onAppear()
        model.allowLocation()
        await waitUntil { model.locationState == .cityCentre }
        XCTAssertEqual(model.locationNote, "Showing city centre")
        assertCentre(model.cameraPosition, is: HomeModel.cityCentre)
        XCTAssertFalse(model.canLocate)
    }

    func testNotNowShowsCityCentre() {
        let model = makeModel()
        model.onAppear()
        model.notNow()
        XCTAssertEqual(model.locationState, .cityCentre)
        XCTAssertEqual(model.locationNote, "Showing city centre")
        XCTAssertFalse(model.showsPrimingCard)
        XCTAssertEqual(location.requests, 0)
    }

    func testAlreadyAuthorisedLocatesOnAppear() async {
        location.authorizationStatus = .authorizedWhenInUse
        let model = makeModel()
        model.onAppear()
        XCTAssertFalse(model.showsPrimingCard, "no priming card while the first fix is coming")
        await waitUntil { model.locationState == .located }
        assertCentre(model.cameraPosition, is: collegeGreen)
        model.onAppear()
        XCTAssertEqual(location.requests, 1, "onAppear runs once")
    }

    func testDeniedAtLaunchShowsCityCentre() {
        location.authorizationStatus = .denied
        let model = makeModel()
        model.onAppear()
        XCTAssertEqual(model.locationState, .cityCentre)
        XCTAssertFalse(model.showsPrimingCard)
    }

    func testPermissionRevokedWhileRunningKeepsMapAndDisablesNearMe() async {
        location.authorizationStatus = .authorizedWhenInUse
        let model = makeModel()
        model.onAppear()
        await waitUntil { model.locationState == .located }
        await loadTimeline(model)
        let before = model.cameraPosition

        location.authorizationStatus = .denied
        await waitUntil { model.locationState == .off }
        XCTAssertEqual(model.cameraPosition, before, "the map stays where it was")
        XCTAssertEqual(model.locationNote, "Location is off")
        XCTAssertFalse(model.canLocate)
        XCTAssertFalse(model.showsPrimingCard)
        XCTAssertEqual(nearbySource.callCount, 1, "no refetch; the timeline still follows the map")

        model.mapCameraSettled(centre: CLLocationCoordinate2D(latitude: 53.36, longitude: -6.26))
        XCTAssertTrue(model.nearby.hasPendingFetch, "everything still works by moving the map")

        // Turned back on in Settings: located again, and the map stays put.
        location.authorizationStatus = .authorizedWhenInUse
        await waitUntil { model.locationState == .located }
        XCTAssertEqual(model.cameraPosition, before)
        XCTAssertNil(model.locationNote)

        // "Allow Once" expiring reverts to not determined: off, no priming card.
        location.authorizationStatus = .notDetermined
        await waitUntil { model.locationState == .off }
        XCTAssertEqual(model.cameraPosition, before)
        XCTAssertFalse(model.showsPrimingCard)
        XCTAssertTrue(model.canLocate, "near me stays enabled: a tap asks again")
        XCTAssertEqual(location.requests, 2, "never re-prompts by itself")
    }

    func testGoNearMeRecentres() async {
        location.authorizationStatus = .authorizedWhenInUse
        let model = makeModel()
        model.onAppear()
        await waitUntil { model.locationState == .located }
        model.cameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 53.40, longitude: -6.30), span: HomeModel.homeSpan))
        model.goNearMe()
        await waitUntil { self.location.requests == 2 }
        await waitUntil { self.centre(of: model.cameraPosition)?.latitude == self.collegeGreen.latitude }
    }

    // MARK: - Timeline and modes

    func testCameraSettledFeedsNearby() async {
        let model = makeModel()
        model.mapCameraSettled(centre: collegeGreen)
        XCTAssertEqual(model.centre.latitude, collegeGreen.latitude)
        XCTAssertTrue(model.nearby.hasPendingFetch)
    }

    func testSelectModeForwardsToBothModels() async {
        let model = makeModel()
        await loadTimeline(model)
        model.selectMode(.train)
        XCTAssertEqual(model.mode, .train)
        XCTAssertEqual(model.nearby.mode, .train)
        XCTAssertEqual(model.search.mode, .train)
        await waitUntil { model.nearby.departures.map(\.route) == ["DART"] }
    }

    func testScenePhaseForwardsToNearby() async {
        let model = makeModel()
        await loadTimeline(model)
        model.scenePhaseChanged(to: .background)
        await waitUntil { self.clock.sleeperCount == 0 }
        model.scenePhaseChanged(to: .active)
        await waitUntil { self.nearbySource.callCount == 2 }
    }

    func testRouteListsRefreshAtLaunchAndOnReturnWithoutOverlapping() async {
        let refreshes = AtomicInt()
        let clock = clock
        // Each refresh takes 1 s of test-clock time, so a test can act mid-refresh.
        let model = makeModel(refreshRoutes: {
            refreshes.value += 1
            await FakeNearbySource.wait(.seconds(1), on: clock)
        })
        model.onAppear()
        await waitUntil("launch refresh running") { refreshes.value == 1 && clock.sleeperCount == 1 }

        model.scenePhaseChanged(to: .background)
        model.scenePhaseChanged(to: .active)
        XCTAssertEqual(refreshes.value, 1, "no second refresh while the launch one runs")

        clock.advance(by: 1)
        await waitUntil("launch refresh done") { clock.sleeperCount == 0 }
        await waitUntil("refresh slot free") { !model.isRefreshingRoutes }
        model.scenePhaseChanged(to: .background)
        model.scenePhaseChanged(to: .active)
        await waitUntil("refreshed on return") { refreshes.value == 2 }
        clock.advance(by: 1)
        await waitUntil { !model.isRefreshingRoutes }
    }

    // MARK: - Search

    func testSearchStateAndCancel() {
        let model = makeModel()
        model.beginSearch()
        XCTAssertEqual(model.screen, .search)
        model.search.query = "col"
        model.cancelSearch()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertEqual(model.search.query, "")
    }

    func testSearchDuringFocusClosesFocusFirst() async {
        let model = makeModel()
        await loadTimeline(model)
        model.openFocus(departure: model.nearby.departures[0])
        XCTAssertNotNil(model.focus)
        await waitUntil("focus polling") { self.focusSource.arrivalFetchCount == 1 }
        await waitUntil("only focus sleeps") { self.clock.sleeperCount == 1 }

        model.beginSearch()
        XCTAssertEqual(model.screen, .search, "the field takes input, so its results must show")
        XCTAssertNil(model.focus)
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
        assertCentre(model.cameraPosition, is: collegeGreen, "the map is back where the timeline was")

        model.cancelSearch()
        XCTAssertEqual(model.screen, .timeline)
    }

    func testStopResultFliesTheMapAndReturnsToTheTimeline() {
        let model = makeModel()
        model.beginSearch()
        let stop = StopSearchResult(id: "S", name: "Heuston", lat: 53.3464, lon: -6.2920, modes: [.train])
        model.selectStopResult(stop)
        XCTAssertEqual(model.screen, .timeline)
        assertCentre(model.cameraPosition, is: stop.coordinate)
        XCTAssertEqual(model.search.query, "")
    }

    func testPlaceResultFliesTheMap() {
        let model = makeModel()
        model.beginSearch()
        let place = PlaceResult(id: "p", name: "Phoenix Park", subtitle: nil, lat: 53.3559, lon: -6.3298)
        model.selectPlaceResult(place)
        XCTAssertEqual(model.screen, .timeline)
        assertCentre(model.cameraPosition, is: place.coordinate)
    }

    func testRouteResultOpensFocusWithoutAStop() async {
        let model = makeModel()
        model.beginSearch()
        let route = RouteSearchResult(name: "46A", agencyId: "1", agencyName: "Dublin Bus", mode: .bus, headsignOutbound: "Dún Laoghaire", headsignInbound: "Phoenix Park")
        model.selectRouteResult(route)
        let expected = RouteFocusTarget(route: route.ref, mode: .bus, direction: 0, headsign: "Dún Laoghaire", stop: nil)
        XCTAssertEqual(model.screen, .focus(expected))
        XCTAssertEqual(model.focus?.route, route.ref)
        XCTAssertEqual(model.search.query, "")

        model.closeFocus()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertTrue(model.nearby.hasPendingFetch, "nothing was fetched before focus: the timeline fetches where the map is")
    }

    // MARK: - Route focus

    func testRouteResultDuringFocusReplacesItAndBackRestoresTheTimeline() async throws {
        let model = makeModel()
        await loadTimeline(model)
        model.openFocus(departure: model.nearby.departures[0])
        let first = try XCTUnwrap(model.focus)
        // Counted by vehicle fetches: the route result's focus has no stop
        // (the store has no stop lists), so it asks for no arrivals.
        await waitUntil("first focus polling") { self.focusSource.vehicleFetchCount == 1 }
        await waitUntil("only focus sleeps") { self.clock.sleeperCount == 1 }
        XCTAssertEqual(nearbySource.callCount, 1)

        let route = RouteSearchResult(name: "46A", agencyId: "1", agencyName: "Dublin Bus", mode: .bus, headsignOutbound: "Dún Laoghaire", headsignInbound: "Phoenix Park")
        model.selectRouteResult(route)
        let second = try XCTUnwrap(model.focus)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.route, route.ref)
        await waitUntil("second focus polling") { self.focusSource.vehicleFetchCount == 2 }
        await waitUntil("one focus loop") { self.clock.sleeperCount == 1 }

        // A first focus still polling would fetch again on the next tick.
        clock.advance(by: 30)
        await waitUntil("second focus refreshed") { self.focusSource.vehicleFetchCount >= 3 }
        for _ in 0..<50 {
            await Task.yield()
            _ = await focusSource.vehicleFetches
        }
        XCTAssertEqual(focusSource.vehicleFetchCount, 3, "the replaced focus stopped polling")
        XCTAssertEqual(nearbySource.callCount, 1, "the timeline stays paused across the replacement")

        model.closeFocus()
        XCTAssertEqual(model.screen, .timeline)
        assertCentre(model.cameraPosition, is: collegeGreen, "the timeline's camera, saved by the first focus")
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
        await waitUntil("nearby polling") { self.clock.sleeperCount == 1 }
        for _ in 0..<50 {
            await Task.yield()
            _ = await nearbySource.calls
        }
        XCTAssertEqual(nearbySource.callCount, 2, "resumed once")
    }

    func testRowOpensFocusWithItsStopAndBackRestoresTheTimeline() async throws {
        let model = makeModel()
        // Once the user pans, the map's position binding holds no region;
        // the timeline's place comes from where the camera settled.
        model.cameraPosition = .automatic
        await loadTimeline(model)
        let wide = MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        model.mapCameraSettled(centre: collegeGreen, span: wide) // zoomed out, same place
        XCTAssertFalse(model.nearby.hasPendingFetch)
        let row = model.nearby.departures[0]

        model.openFocus(departure: row)
        let expected = RouteFocusTarget(route: row.routeRef, mode: .bus, direction: 0, headsign: "Ongar", stop: FocusStop(SampleData.collegeGreen))
        XCTAssertEqual(model.screen, .focus(expected))
        let focus = try XCTUnwrap(model.focus)
        await waitUntil("focus loaded") { !focus.isLoading }
        await waitUntil("camera fits the stop") { self.centre(of: model.cameraPosition)?.latitude == SampleData.collegeGreen.lat }
        await waitUntil("focus polling") { self.focusSource.arrivalFetchCount == 1 }
        await waitUntil("only focus sleeps") { self.clock.sleeperCount == 1 } // nearby is paused while focus polls

        model.mapCameraSettled(centre: CLLocationCoordinate2D(latitude: 53.30, longitude: -6.20))
        XCTAssertFalse(model.nearby.hasPendingFetch, "the focus camera never refetches the timeline")

        model.closeFocus()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertNil(model.focus)
        assertCentre(model.cameraPosition, is: collegeGreen, "the map goes back to where the timeline was")
        XCTAssertEqual(model.cameraPosition.region?.span.latitudeDelta, wide.latitudeDelta, "at the timeline's zoom")
        let fetched = try XCTUnwrap(model.nearby.fetchedCentre)
        assertCentre(model.cameraPosition, is: fetched, "the resumed fetch is for the place the map shows")
        await waitUntil { self.nearbySource.callCount == 2 }
        let calls = await nearbySource.calls
        XCTAssertEqual(calls.last?.lat, collegeGreen.latitude)
        XCTAssertEqual(model.nearby.departures.count, 2, "rows are intact")
    }
}
