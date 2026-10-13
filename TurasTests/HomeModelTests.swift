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
    private let stopSource = FakeStopSource()
    private let stationSource = FakeStationSource()
    private let location = FakeLocation()
    private let collegeGreen = CLLocationCoordinate2D(latitude: 53.3441, longitude: -6.2595)
    private let collegeGreenStop = StopTarget(SampleData.collegeGreen, mode: .bus)
    private let dameStreetStop = StopTarget(SampleData.dameStreet, mode: .bus)

    private func makeModel(refreshRoutes: HomeModel.RouteRefresh? = nil) -> HomeModel {
        let nearby = NearbyModel(source: nearbySource, clock: clock.appClock)
        let search = SearchModel(source: FakeSearchSource(), places: NoPlaces(), clock: clock.appClock)
        let stations = StationStore(source: stationSource)
        let store = StaticDataStore(source: EmptyStaticSource(), bundledStops: RouteStopService(stopsByRoute: [:]), cacheDirectory: nil, bundledRoutes: { [:] })
        let clock = clock
        let focusSource = focusSource
        let stopSource = stopSource
        return HomeModel(nearby: nearby, search: search, stations: stations, location: location, refreshRoutes: refreshRoutes, makeFocus: { target, centre, userLocation in
            RouteFocusModel(target: target, centre: centre, userLocation: userLocation, source: focusSource,
                            staticData: store, shapes: RouteShapeService(shapes: [:]), clock: clock.appClock, headsignLookup: [:])
        }, makeStop: { target, userLocation in
            StopModel(target: target, userLocation: userLocation, source: stopSource, clock: clock.appClock)
        })
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

    func testStopResultOpensTheStopViewDirectly() async {
        let model = makeModel()
        await loadTimeline(model)
        model.beginSearch()
        let result = StopSearchResult(id: SampleData.taraStreet.id, name: "Tara Street", lat: SampleData.taraStreet.lat, lon: SampleData.taraStreet.lon, modes: [.train])
        model.selectStopResult(result)

        let expected = StopTarget(id: result.id, name: "Tara Street", lat: result.lat, lon: result.lon, mode: .train)
        XCTAssertEqual(model.screen, .stop(expected), "straight to the stop view, as the stop's own mode")
        XCTAssertEqual(model.mode, .bus, "the tab is unchanged")
        XCTAssertEqual(model.search.query, "")
        assertCentre(model.cameraPosition, is: result.coordinate)
        XCTAssertEqual(model.cameraPosition.region?.span.latitudeDelta, HomeModel.homeSpan.latitudeDelta, "at the home zoom")
        await waitUntil { model.stop?.departures.map(\.route) == ["DART"] }

        model.closeStop()
        XCTAssertEqual(model.screen, .timeline)
        assertCentre(model.cameraPosition, is: collegeGreen, "back where the timeline was")
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

    // MARK: - Stop view

    /// Opens the stop view for a stop and waits for its first answer.
    private func openStop(_ model: HomeModel, _ target: StopTarget) async {
        model.openStop(target)
        await waitUntil("stop loaded") { model.stop?.status == .loaded && model.stop?.target == target }
        await waitUntil("stop polling") { self.clock.sleeperCount == 1 }
    }

    /// Lets any wrongly running loop take its turn (no clock time passes).
    private func drain() async {
        for _ in 0..<50 {
            await Task.yield()
            _ = await stopSource.stopIds
        }
    }

    func testPinTapOpensTheStopViewAndPausesTheTimeline() async throws {
        let model = makeModel()
        await loadTimeline(model)
        await openStop(model, collegeGreenStop)

        XCTAssertEqual(model.screen, .stop(collegeGreenStop))
        let stop = try XCTUnwrap(model.stop)
        XCTAssertEqual(stop.departures.map(\.route), ["39A", "46A"])
        assertCentre(model.cameraPosition, is: collegeGreenStop.coordinate, "the map centres on the stop")
        XCTAssertEqual(stopSource.callCount, 1)

        clock.advance(by: 30)
        await waitUntil("stop refreshed") { self.stopSource.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(nearbySource.callCount, 1, "the timeline is paused under the stop view")

        model.openStop(collegeGreenStop)
        XCTAssertTrue(model.stop === stop, "the same pin again changes nothing")

        // The user pans and zooms in the stop view: past the settle delay,
        // still no timeline fetch, but the zoom is kept for the next pin.
        let elsewhere = CLLocationCoordinate2D(latitude: 53.30, longitude: -6.20)
        let close = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        model.mapCameraSettled(centre: elsewhere, span: close)
        await drain()
        // NearbyModel's pause also blocks a settle timer; HomeModel's `.stop` return is defence in depth.
        XCTAssertEqual(clock.sleeperCount, 1, "only the stop view's loop sleeps: no settle timer for the timeline")
        clock.advance(by: 0.6)
        await drain()
        XCTAssertEqual(nearbySource.callCount, 1, "moving the map in the stop view never refetches the timeline")
        model.openStop(dameStreetStop)
        XCTAssertEqual(model.cameraPosition.region?.span.latitudeDelta, close.latitudeDelta, "the zoom set in the stop view is kept")

        model.closeStop()
        assertCentre(model.cameraPosition, is: collegeGreen, "the timeline's place, not where the stop view's map went")
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
        let calls = await nearbySource.calls
        XCTAssertEqual(calls.last?.lat, collegeGreen.latitude)
    }

    func testRowInStopViewOpensFocusAndBackReturnsToTheStopThenTheTimeline() async throws {
        let model = makeModel()
        model.cameraPosition = .automatic
        await loadTimeline(model)
        let wide = MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        model.mapCameraSettled(centre: collegeGreen, span: wide) // zoomed out, same place
        await openStop(model, dameStreetStop)
        let stop = try XCTUnwrap(model.stop)
        XCTAssertEqual(model.cameraPosition.region?.span.latitudeDelta, wide.latitudeDelta, "a pin keeps the user's zoom")
        let row = try XCTUnwrap(stop.departures.first)

        model.openFocus(departure: row)
        let expected = RouteFocusTarget(route: row.routeRef, mode: .bus, direction: 1, headsign: "Ballinteer",
                                        stop: FocusStop(id: dameStreetStop.id, name: "Dame Street", lat: dameStreetStop.lat, lon: dameStreetStop.lon))
        XCTAssertEqual(model.screen, .focus(expected))
        XCTAssertTrue(model.stop === stop, "the stop view waits under focus (its back button says Back to stop)")
        await waitUntil("focus polling") { self.focusSource.arrivalFetchCount == 1 }
        await waitUntil("only focus sleeps") { self.clock.sleeperCount == 1 }
        clock.advance(by: 30)
        await waitUntil { self.focusSource.arrivalFetchCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(stopSource.callCount, 1, "the stop view is paused under focus")
        XCTAssertEqual(nearbySource.callCount, 1, "and the timeline under both")

        model.closeFocus()
        XCTAssertEqual(model.screen, .stop(dameStreetStop), "back goes to the stop view, not the timeline")
        XCTAssertNil(model.focus)
        assertCentre(model.cameraPosition, is: dameStreetStop.coordinate, "centred on the stop again")
        XCTAssertEqual(model.cameraPosition.region?.span.latitudeDelta, wide.latitudeDelta, "at the user's zoom")
        await waitUntil("stop resumed with a fetch") { self.stopSource.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }

        model.closeStop()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertNil(model.stop)
        assertCentre(model.cameraPosition, is: collegeGreen, "the camera saved when the stop view opened")
        XCTAssertEqual(model.cameraPosition.region?.span.latitudeDelta, wide.latitudeDelta)
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
        XCTAssertEqual(model.nearby.departures.count, 2, "rows are intact")
        await waitUntil { self.clock.sleeperCount == 1 }
        await drain()
        XCTAssertEqual(stopSource.callCount, 2, "the closed stop view stopped polling")
    }

    func testTappingAnotherPinSwitchesStopAndStopsTheOldOne() async throws {
        let model = makeModel()
        await loadTimeline(model)
        await openStop(model, collegeGreenStop)
        let first = try XCTUnwrap(model.stop)

        await openStop(model, dameStreetStop)
        let second = try XCTUnwrap(model.stop)
        XCTAssertFalse(first === second)
        XCTAssertEqual(model.screen, .stop(dameStreetStop))
        XCTAssertEqual(second.departures.map(\.route), ["16"])
        assertCentre(model.cameraPosition, is: dameStreetStop.coordinate)

        clock.advance(by: 30)
        await waitUntil { self.stopSource.callCount == 3 }
        await waitUntil { self.clock.sleeperCount == 1 }
        await drain()
        let stopIds = await stopSource.stopIds
        XCTAssertEqual(stopIds, [collegeGreenStop.id, dameStreetStop.id, dameStreetStop.id], "the replaced stop view stopped polling")
        XCTAssertEqual(nearbySource.callCount, 1, "the timeline stays paused across the switch")

        model.closeStop()
        assertCentre(model.cameraPosition, is: collegeGreen, "the timeline's camera, saved by the first stop view")
        await waitUntil { self.nearbySource.callCount == 2 }
    }

    func testSwitchingStopBeforeTheFirstAnswerArrivesDropsThatAnswer() async throws {
        let model = makeModel()
        await loadTimeline(model)
        await stopSource.hold(collegeGreenStop.id)
        model.openStop(collegeGreenStop)
        let first = try XCTUnwrap(model.stop)
        await waitUntil("College Green asked, answer held") { self.stopSource.callCount == 1 }

        await openStop(model, dameStreetStop)
        await stopSource.release(collegeGreenStop.id)
        await waitUntil("College Green's late answer delivered") { self.stopSource.answerCount == 2 }
        await drain()

        XCTAssertEqual(model.screen, .stop(dameStreetStop))
        XCTAssertEqual(model.stop?.departures.map(\.route), ["16"], "the stop view shows Dame Street's rows")
        XCTAssertTrue(first.departures.isEmpty, "the replaced stop view dropped the late answer")
        XCTAssertEqual(first.status, .loading)
        await waitUntil { self.clock.sleeperCount == 1 }
        await drain()
        XCTAssertEqual(stopSource.callCount, 2, "the replaced stop view never started polling")
        model.closeStop()
    }

    func testStopOpenedBeforeTheFirstFetchStillFetchesOnBack() async {
        let model = makeModel()
        model.openStop(collegeGreenStop)
        XCTAssertEqual(model.screen, .stop(collegeGreenStop))
        await waitUntil { model.stop?.status == .loaded }
        model.closeStop()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertTrue(model.nearby.hasPendingFetch, "nothing was fetched before the stop view: the timeline fetches where the map is")
    }

    func testScenePhaseInTheStopViewPausesTheStopNotTheTimeline() async {
        let model = makeModel()
        await loadTimeline(model)
        await openStop(model, collegeGreenStop)

        model.scenePhaseChanged(to: .background)
        await waitUntil { self.clock.sleeperCount == 0 }
        model.scenePhaseChanged(to: .active)
        await waitUntil { self.stopSource.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(nearbySource.callCount, 1, "the timeline stays paused")
        model.closeStop()
    }

    func testPinTappedDuringSearchClearsTheSearch() async {
        let model = makeModel()
        await loadTimeline(model)
        model.beginSearch()
        model.search.query = "dame"

        model.openStop(dameStreetStop)
        XCTAssertEqual(model.screen, .stop(dameStreetStop))
        XCTAssertEqual(model.search.query, "", "the search is over")
        await waitUntil { model.stop?.status == .loaded }

        model.closeStop()
        XCTAssertEqual(model.screen, .timeline)
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
    }

    func testSearchDuringTheStopViewClosesItFirst() async {
        let model = makeModel()
        await loadTimeline(model)
        await openStop(model, collegeGreenStop)

        model.beginSearch()
        XCTAssertEqual(model.screen, .search)
        XCTAssertNil(model.stop)
        assertCentre(model.cameraPosition, is: collegeGreen)
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
        model.cancelSearch()
        XCTAssertEqual(model.screen, .timeline)
    }

    func testSearchDuringFocusOverTheStopViewClosesBoth() async throws {
        let model = makeModel()
        await loadTimeline(model)
        await openStop(model, collegeGreenStop)
        let row = try XCTUnwrap(model.stop?.departures.first)
        model.openFocus(departure: row)
        await waitUntil { self.focusSource.arrivalFetchCount == 1 }

        model.beginSearch()
        XCTAssertEqual(model.screen, .search)
        XCTAssertNil(model.focus)
        XCTAssertNil(model.stop)
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
        await drain()
        XCTAssertEqual(stopSource.callCount, 1, "the closed stop view did not resume on the way out")
    }

    func testClosingTheStopViewUnderFocusClosesFocusToo() async throws {
        let model = makeModel()
        await loadTimeline(model)
        await openStop(model, collegeGreenStop)
        let row = try XCTUnwrap(model.stop?.departures.first)
        model.openFocus(departure: row)
        await waitUntil("focus polling") { self.focusSource.arrivalFetchCount == 1 }
        await waitUntil("only focus sleeps") { self.clock.sleeperCount == 1 }

        model.closeStop()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertNil(model.focus, "never on the timeline with focus still open")
        XCTAssertNil(model.stop)
        assertCentre(model.cameraPosition, is: collegeGreen, "the camera saved when the stop view opened")
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
        await waitUntil("only the timeline sleeps") { self.clock.sleeperCount == 1 }
        clock.advance(by: 30)
        await waitUntil { self.nearbySource.callCount == 3 }
        await waitUntil { self.clock.sleeperCount == 1 }
        await drain()
        XCTAssertEqual(focusSource.arrivalFetchCount, 1, "the closed focus stopped polling")
        XCTAssertEqual(stopSource.callCount, 1, "the closed stop view did not resume")
    }

    func testStopOpenedOverFocusFromTheTimelineClosesFocus() async throws {
        let model = makeModel()
        await loadTimeline(model)
        let route = RouteSearchResult(name: "46A", agencyId: "1", agencyName: "Dublin Bus", mode: .bus, headsignOutbound: "Dún Laoghaire", headsignInbound: "Phoenix Park")
        model.selectRouteResult(route)
        await waitUntil("focus polling") { self.focusSource.vehicleFetchCount == 1 }
        await waitUntil("only focus sleeps") { self.clock.sleeperCount == 1 }
        XCTAssertNil(model.stop, "focus from the timeline has no stop view to go back to")

        model.openStop(collegeGreenStop)
        XCTAssertEqual(model.screen, .stop(collegeGreenStop))
        XCTAssertNil(model.focus)
        await waitUntil("stop loaded") { model.stop?.status == .loaded }
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 30)
        await waitUntil { self.stopSource.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        await drain()
        XCTAssertEqual(focusSource.vehicleFetchCount, 1, "the closed focus stopped polling")
        XCTAssertEqual(nearbySource.callCount, 1, "the timeline stays paused")

        model.closeStop()
        XCTAssertEqual(model.screen, .timeline)
        assertCentre(model.cameraPosition, is: collegeGreen, "the camera saved when focus opened")
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
    }

    func testStopOpenedOverFocusFromTheStopViewResumesOrReplacesIt() async throws {
        let model = makeModel()
        await loadTimeline(model)
        await openStop(model, collegeGreenStop)
        let first = try XCTUnwrap(model.stop)
        let row = try XCTUnwrap(first.departures.first)
        model.openFocus(departure: row)
        await waitUntil("focus polling") { self.focusSource.arrivalFetchCount == 1 }
        await waitUntil("only focus sleeps") { self.clock.sleeperCount == 1 }

        model.openStop(collegeGreenStop)
        XCTAssertEqual(model.screen, .stop(collegeGreenStop), "never left in focus with no focus model")
        XCTAssertNil(model.focus)
        XCTAssertTrue(model.stop === first, "the same stop view, resumed")
        await waitUntil("stop resumed with a fetch") { self.stopSource.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }

        model.openFocus(departure: row)
        await waitUntil { self.focusSource.arrivalFetchCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        model.openStop(dameStreetStop)
        XCTAssertEqual(model.screen, .stop(dameStreetStop))
        XCTAssertNil(model.focus)
        let second = try XCTUnwrap(model.stop)
        XCTAssertFalse(first === second)
        await waitUntil { second.status == .loaded }
        await waitUntil { self.clock.sleeperCount == 1 }
        await drain()
        let stopIds = await stopSource.stopIds
        XCTAssertEqual(stopIds, [collegeGreenStop.id, collegeGreenStop.id, dameStreetStop.id], "the replaced stop view never fetched again")
        XCTAssertEqual(focusSource.arrivalFetchCount, 2, "the closed focus stopped polling")
        XCTAssertEqual(nearbySource.callCount, 1, "the timeline stays paused throughout")

        model.closeStop()
        assertCentre(model.cameraPosition, is: collegeGreen, "the camera saved when the first stop view opened")
        await waitUntil("nearby resumed") { self.nearbySource.callCount == 2 }
    }

    func testLuasPinsComeFromStationsAndFallBackToNearbyStops() async {
        let model = makeModel()
        await loadTimeline(model)
        XCTAssertEqual(model.pins.map(\.id), [SampleData.collegeGreen.id, SampleData.dameStreet.id], "bus pins are /nearby's stops")
        XCTAssertEqual(model.pins.first?.mode, .bus)

        await stationSource.setError(URLError(.notConnectedToInternet))
        model.selectMode(.luas)
        await waitUntil { model.nearby.departures.map(\.route) == ["Red"] }
        await waitUntil("stations asked and failed") { self.stationSource.callCount == 1 && !model.stations.isLoading(.luas) }
        XCTAssertEqual(model.pins.map(\.id), [SampleData.abbeyStreet.id], "/stations failed: /nearby's stops are the pins")
        XCTAssertEqual(model.pins.first?.mode, .luas)

        await stationSource.setError(nil)
        model.selectMode(.bus)
        model.selectMode(.luas)
        await waitUntil("stations loaded on the next selection") { model.pins.map(\.id) == ["LUAS-ABB", "LUAS-JER"] }
        XCTAssertEqual(stationSource.callCount, 2)

        model.selectMode(.bus)
        await waitUntil { model.pins.map(\.id) == [SampleData.collegeGreen.id, SampleData.dameStreet.id] }
        model.selectMode(.luas)
        XCTAssertEqual(model.pins.map(\.id), ["LUAS-ABB", "LUAS-JER"], "kept for the session, bus never uses it")
        XCTAssertEqual(stationSource.callCount, 2, "one fetch per mode")
        let modes = await stationSource.modes
        XCTAssertEqual(modes, [.luas, .luas])
    }

    func testMapPinsHighlightTheStopViewsStopAndAddItWhenMissing() async throws {
        let model = makeModel()
        await loadTimeline(model)
        let ids = [SampleData.collegeGreen.id, SampleData.dameStreet.id]
        XCTAssertEqual(model.mapPins.map(\.id), ids)
        XCTAssertEqual(model.mapPins.map(\.target), model.pins)
        XCTAssertFalse(model.mapPins.contains { $0.isHighlighted }, "nothing is highlighted on the timeline")

        await openStop(model, dameStreetStop)
        XCTAssertEqual(model.mapPins.map(\.id), ids, "a pin's own stop is not drawn twice")
        XCTAssertEqual(model.mapPins.filter(\.isHighlighted).map(\.id), [SampleData.dameStreet.id])

        // A stop reached by search can lie outside the pins fetched for the timeline's place.
        let tara = StopTarget(SampleData.taraStreet, mode: .train)
        await openStop(model, tara)
        XCTAssertEqual(model.pins.map(\.id), ids, "the mode's own pins are unchanged")
        XCTAssertEqual(model.mapPins.map(\.id), ids + [tara.id], "the stop view's stop still gets its pin")
        XCTAssertEqual(model.mapPins.last?.target, tara)
        XCTAssertEqual(model.mapPins.filter(\.isHighlighted).map(\.id), [tara.id])

        model.closeStop()
        XCTAssertEqual(model.mapPins.map(\.id), ids)
        XCTAssertFalse(model.mapPins.contains { $0.isHighlighted })
    }
}
