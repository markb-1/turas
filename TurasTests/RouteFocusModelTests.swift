import CoreLocation
import MapKit
import SwiftUI
import XCTest
@testable import Turas

/// Stops per route and direction, served to StaticDataStore. A hold makes
/// the next stops fetch for a route and direction sleep on the test clock,
/// so a test can act while a load is in flight.
private actor FakeStaticSource: StaticDataSource {
    private let clock: ManualClock?
    private var stops: [String: [RouteStop]] = [:]
    private var routes: [TransportMode: [TransitRoute]] = [:]
    private var holds: [String: Duration] = [:]
    /// Fetches that have reached a hold, readable without awaiting.
    nonisolated var heldCount: Int { heldBox.value }
    private nonisolated let heldBox = AtomicInt()

    init(clock: ManualClock? = nil) {
        self.clock = clock
    }

    func setStops(_ stops: [RouteStop], route: String, direction: Int) {
        self.stops["\(route)|\(direction)"] = stops
    }

    func setRoutes(_ routes: [TransportMode: [TransitRoute]]) { self.routes = routes }

    /// Holds the next stops fetch for `route` and `direction` for `delay` of test-clock time.
    func setHold(_ delay: Duration, route: String, direction: Int) {
        holds["\(route)|\(direction)"] = delay
    }

    func fetchRoutes(mode: TransportMode) async throws -> [TransitRoute] { routes[mode] ?? [] }

    func fetchStops(route: String, agency: String?, direction: Int) async throws -> [RouteStop] {
        let key = "\(route)|\(direction)"
        if let delay = holds.removeValue(forKey: key), let clock {
            heldBox.value += 1
            await FakeNearbySource.wait(delay, on: clock)
        }
        return stops[key] ?? []
    }
}

@MainActor
final class RouteFocusModelTests: XCTestCase {
    private let clock = ManualClock()
    private let centre = CLLocationCoordinate2D(latitude: 53.3441, longitude: -6.2595)
    private let route39A = RouteRef(name: "39A", agencyId: "1")

    private func stop(_ id: String, _ name: String, lat: Double, lon: Double, seq: Int) -> RouteStop {
        RouteStop(id: id, name: name, lat: lat, lon: lon, seq: seq, t: seq * 60)
    }

    // Outbound runs west along Dame Street; inbound runs back on the other side.
    private lazy var outbound = [
        stop("A", "College Green", lat: 53.3441, lon: -6.2595, seq: 1),
        stop("B", "Dame Street", lat: 53.3439, lon: -6.2660, seq: 2),
        stop("C", "Christchurch", lat: 53.3434, lon: -6.2710, seq: 3),
        stop("FAR", "Ongar", lat: 53.3990, lon: -6.4350, seq: 4),
    ]
    private lazy var inbound = [
        stop("C2", "Christchurch (inbound)", lat: 53.3436, lon: -6.2712, seq: 1),
        stop("B2", "Dame Street (inbound)", lat: 53.3441, lon: -6.2658, seq: 2),
        stop("A2", "College Green (inbound)", lat: 53.3443, lon: -6.2593, seq: 3),
    ]
    private let shape0 = RouteShape(direction: 0, coordinates: [[53.3441, -6.2595], [53.3439, -6.2660], [53.3434, -6.2710], [53.3990, -6.4350]])
    private let shape1 = RouteShape(direction: 1, coordinates: [[53.3436, -6.2712], [53.3443, -6.2593]])

    private func vehicle(_ id: String, route: String, agency: String? = "1", direction: Int, mode: TransportMode = .bus) -> Vehicle {
        Vehicle(id: id, tripId: "t-\(id)", routeId: route, agencyId: agency, headsign: nil, direction: direction,
                latitude: 53.34, longitude: -6.26, bearing: nil, timestamp: clock.now, mode: mode)
    }

    private func arrival(_ id: String, minutes: Int) -> StopArrival {
        StopArrival(id: id, routeId: "39A", headsign: "Ongar", delay: 0,
                    predictedArrival: clock.now.addingTimeInterval(TimeInterval(minutes * 60)), isLive: true, isCancelled: false)
    }

    private func makeModel(
        target: RouteFocusTarget,
        source: FakeFocusSource = FakeFocusSource(),
        staticSource: FakeStaticSource,
        shapes: [String: [RouteShape]],
        userLocation: CLLocationCoordinate2D? = nil
    ) -> RouteFocusModel {
        let store = StaticDataStore(
            source: staticSource,
            bundledStops: RouteStopService(stopsByRoute: [:]),
            cacheDirectory: nil,
            bundledRoutes: { [:] }
        )
        return RouteFocusModel(
            target: target, centre: centre, userLocation: userLocation, source: source, staticData: store,
            shapes: RouteShapeService(shapes: shapes), clock: clock.appClock, headsignLookup: ["39A_0": "Ongar", "39A_1": "UCD"]
        )
    }

    private func staticSource() async -> FakeStaticSource {
        let source = FakeStaticSource(clock: clock)
        await source.setStops(outbound, route: "39A", direction: 0)
        await source.setStops(inbound, route: "39A", direction: 1)
        return source
    }

    private func target(stop: FocusStop?, direction: Int = 0, headsign: String? = "Ongar") -> RouteFocusTarget {
        RouteFocusTarget(route: route39A, mode: .bus, direction: direction, headsign: headsign, stop: stop)
    }

    // MARK: - Loading

    func testLoadsStopsShapeAndHighlightsRequestedStop() async {
        let source = FakeFocusSource()
        await source.setVehicles([vehicle("v1", route: "39A", direction: 0), vehicle("v2", route: "39A", direction: 1),
                                  vehicle("v3", route: "46A", direction: 0), vehicle("v4", route: "39A", agency: "2", direction: 0)])
        await source.setArrivals([arrival("a1", minutes: 4)])
        let model = makeModel(target: target(stop: FocusStop(outbound[1])), source: source,
                              staticSource: await staticSource(), shapes: ["39A": [shape0, shape1]],
                              userLocation: centre)
        await model.start()

        XCTAssertEqual(model.stops.map(\.id), ["A", "B", "C", "FAR"])
        XCTAssertEqual(model.shape?.direction, 0)
        XCTAssertEqual(model.highlightedStop?.id, "B", "matched by id against the route's stops")
        XCTAssertEqual(model.highlightedStop?.name, "Dame Street")
        XCTAssertEqual(model.headsign, "Ongar")
        XCTAssertEqual(model.vehicles.map(\.id), ["v1"], "same route, agency and direction only")
        XCTAssertEqual(model.arrivals.map(\.id), ["a1"])
        XCTAssertEqual(model.lastUpdated, clock.now)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.walkingMinutes, GeoUtils.walkingMinutes(metres: 434), "from the user's location")
        let request = await source.lastArrivalRequest
        XCTAssertEqual(request?.stopId, "B")
        XCTAssertEqual(request?.route, route39A)
        XCTAssertEqual(request?.direction, 0)
    }

    func testRequestedStopMissingFromListIsStillUsed() async {
        // The timeline's stop came from the server; the route's stop list may
        // be older bundled data without it. The pin's own stop wins.
        let pin = FocusStop(id: "NEW", name: "New Stop", lat: 53.3440, lon: -6.2600)
        let model = makeModel(target: target(stop: pin), staticSource: await staticSource(), shapes: ["39A": [shape0]])
        await model.start()
        XCTAssertEqual(model.highlightedStop?.id, "NEW")
        XCTAssertEqual(model.highlightedStop?.name, "New Stop")
        XCTAssertEqual(Double(model.distanceFromCentre ?? 0), 35, accuracy: 1)
        XCTAssertNil(model.walkingMinutes, "no user location")
    }

    func testRouteWithoutShapeStillFocuses() async {
        let model = makeModel(target: target(stop: FocusStop(outbound[0])), staticSource: await staticSource(), shapes: [:])
        await model.start()
        XCTAssertNil(model.shape)
        XCTAssertEqual(model.highlightedStop?.id, "A")
        let region = try! XCTUnwrap(model.focusRegion)
        XCTAssertEqual(region.center.latitude, 53.3441, accuracy: 1e-6)
        XCTAssertEqual(region.span.latitudeDelta, 0.008, accuracy: 1e-9)
    }

    func testNoRequestedStopPicksNearestToCentre() async {
        // From a route search result: no stop yet.
        let model = makeModel(target: target(stop: nil), staticSource: await staticSource(), shapes: ["39A": [shape0]])
        await model.start()
        XCTAssertEqual(model.highlightedStop?.id, "A")
    }

    func testHeadsignFallsBackToRouteListThenBundle() async {
        let staticSource = await staticSource()
        await staticSource.setRoutes([.bus: [TransitRoute(name: "39A", agencyId: "1", headsignOutbound: "Ongar (server)", headsignInbound: nil, directions: [0, 1])]])
        let store = StaticDataStore(source: staticSource, bundledStops: RouteStopService(stopsByRoute: [:]), cacheDirectory: nil, bundledRoutes: { [:] })
        await store.refreshRoutesIfStale()
        let model = RouteFocusModel(
            target: target(stop: nil, headsign: nil), centre: centre, userLocation: nil, source: FakeFocusSource(),
            staticData: store, shapes: RouteShapeService(shapes: [:]), clock: clock.appClock, headsignLookup: ["39A_1": "UCD (bundle)"]
        )
        await model.start()
        XCTAssertEqual(model.headsign, "Ongar (server)")
        await model.flipDirection()
        XCTAssertEqual(model.headsign, "UCD (bundle)")
    }

    // MARK: - Flipping

    func testFlipDirectionPicksNearestStopInOtherDirection() async {
        let source = FakeFocusSource()
        let model = makeModel(target: target(stop: FocusStop(outbound[1])), source: source,
                              staticSource: await staticSource(), shapes: ["39A": [shape0, shape1]])
        await model.start()
        XCTAssertEqual(model.highlightedStop?.id, "B")

        await model.flipDirection()
        XCTAssertEqual(model.direction, 1)
        XCTAssertEqual(model.headsign, "UCD", "from the bundled lookup")
        XCTAssertEqual(model.stops.map(\.id), ["C2", "B2", "A2"])
        XCTAssertEqual(model.shape?.direction, 1)
        XCTAssertEqual(model.highlightedStop?.id, "B2", "the stop across the road")
        let request = await source.lastArrivalRequest
        XCTAssertEqual(request?.direction, 1)
        XCTAssertEqual(request?.stopId, "B2")
    }

    // MARK: - Refreshing

    func testRefreshesEvery30SecondsAndStopsOnStop() async {
        let source = FakeFocusSource()
        let model = makeModel(target: target(stop: nil), source: source, staticSource: await staticSource(), shapes: [:])
        await model.start()
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(source.arrivalFetchCount, 1)

        clock.advance(by: 30)
        await waitUntil { source.arrivalFetchCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }

        model.scenePhaseChanged(to: .background)
        await waitUntil { self.clock.sleeperCount == 0 }
        clock.advance(by: 60)
        XCTAssertEqual(source.arrivalFetchCount, 2)

        model.scenePhaseChanged(to: .active)
        await waitUntil { source.arrivalFetchCount == 3 }

        model.stop()
        await waitUntil { self.clock.sleeperCount == 0 }
    }

    func testErrorKeepsLastArrivalsAndVehicles() async {
        let source = FakeFocusSource()
        await source.setArrivals([arrival("a1", minutes: 4)])
        await source.setVehicles([vehicle("v1", route: "39A", direction: 0)])
        let model = makeModel(target: target(stop: nil), source: source, staticSource: await staticSource(), shapes: [:])
        await model.start()
        XCTAssertNil(model.errorMessage)

        await source.setError(URLError(.notConnectedToInternet))
        await model.refresh()
        XCTAssertEqual(model.arrivals.map(\.id), ["a1"])
        XCTAssertEqual(model.vehicles.map(\.id), ["v1"])
        XCTAssertEqual(model.errorMessage, "No internet connection. Check your network.")

        await source.setError(nil)
        await model.refresh()
        XCTAssertNil(model.errorMessage)
    }

    func testLuasUsesLuasArrivalsAndHasNoVehicles() async {
        let source = FakeFocusSource()
        await source.setLuasArrivals([arrival("l1", minutes: 3)])
        await source.setVehicles([vehicle("tram", route: "Green", agency: "10000", direction: 0, mode: .luas)])
        let staticSource = FakeStaticSource()
        await staticSource.setStops([stop("ABB", "Abbey Street", lat: 53.3485, lon: -6.2583, seq: 1)], route: "Green", direction: 0)
        let target = RouteFocusTarget(route: RouteRef(name: "Green", agencyId: "10000"), mode: .luas, direction: 0, headsign: "Brides Glen", stop: nil)
        let model = makeModel(target: target, source: source, staticSource: staticSource, shapes: [:])
        await model.start()

        XCTAssertEqual(model.arrivals.map(\.id), ["l1"])
        XCTAssertEqual(model.vehicles, [], "the Luas has no live positions")
        let vehicleFetches = await source.vehicleFetches
        XCTAssertEqual(vehicleFetches, 0, "and the app does not ask")
        let luasFetches = await source.luasFetches
        XCTAssertEqual(luasFetches, 1)
        let arrivalFetches = await source.arrivalFetches
        XCTAssertEqual(arrivalFetches, 0)
    }

    func testFlipBackRestoresTheTargetHeadsign() async {
        let model = makeModel(target: target(stop: FocusStop(outbound[1]), headsign: "Ongar (row)"),
                              staticSource: await staticSource(), shapes: ["39A": [shape0, shape1]])
        await model.start()
        XCTAssertEqual(model.headsign, "Ongar (row)")
        await model.flipDirection()
        XCTAssertEqual(model.headsign, "UCD", "from the bundled lookup")
        await model.flipDirection()
        XCTAssertEqual(model.direction, 0)
        XCTAssertEqual(model.headsign, "Ongar (row)", "the row's headsign, not the lookup's")
        model.stop()
    }

    func testRefreshDuringFlipLoadDoesNotFetchWithTheOldStop() async {
        let source = FakeFocusSource()
        let staticSource = await staticSource()
        let model = makeModel(target: target(stop: FocusStop(outbound[1])), source: source,
                              staticSource: staticSource, shapes: ["39A": [shape0, shape1]])
        await model.start()
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(source.arrivalFetchCount, 1)

        await staticSource.setHold(.seconds(5), route: "39A", direction: 1)
        let flip = Task { await model.flipDirection() }
        await waitUntil("the inbound stops fetch is held") { staticSource.heldCount == 1 }
        // Only the held fetch sleeps: the flip cancelled the 30 s loop first.
        await waitUntil("the loop's sleeper is gone") { self.clock.sleeperCount == 1 }
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.direction, 1)
        XCTAssertEqual(model.highlightedStop?.id, "B", "still the outbound stop mid-load")

        // A tick or an immediate resume landing mid-load must not ask for
        // the outbound stop's arrivals in the inbound direction.
        await model.refresh()
        XCTAssertEqual(source.arrivalFetchCount, 1)

        clock.advance(by: 5)
        await flip.value
        XCTAssertEqual(source.arrivalFetchCount, 2)
        let request = await source.lastArrivalRequest
        XCTAssertEqual(request?.stopId, "B2")
        XCTAssertEqual(request?.direction, 1)
        model.stop()
    }

    func testForegroundAfterStopDoesNotRestartRefreshing() async {
        let source = FakeFocusSource()
        let model = makeModel(target: target(stop: nil), source: source, staticSource: await staticSource(), shapes: [:])
        await model.start()
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(source.arrivalFetchCount, 1)

        model.stop()
        await waitUntil { self.clock.sleeperCount == 0 }
        model.scenePhaseChanged(to: .background)
        model.scenePhaseChanged(to: .active)
        // Absence check: let a wrongly restarted loop run its immediate
        // refresh (main-actor turns and actor hops; no clock time passes).
        for _ in 0..<50 {
            await Task.yield()
            _ = await source.vehicleFetches
        }
        XCTAssertEqual(source.arrivalFetchCount, 1, "a closed focus stays closed")
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    // MARK: - Pure helpers

    func testPickStop() {
        let point = CLLocationCoordinate2D(latitude: 53.3439, longitude: -6.2661)
        XCTAssertEqual(RouteFocusModel.pickStop(requested: FocusStop(outbound[2]), in: outbound, nearestTo: point)?.id, "C", "id match first")
        let unknown = FocusStop(id: "X", name: "X", lat: 53.3439, lon: -6.2661)
        XCTAssertEqual(RouteFocusModel.pickStop(requested: unknown, in: outbound, nearestTo: point)?.id, "X", "a requested stop not in the list is used as is")
        XCTAssertEqual(RouteFocusModel.pickStop(requested: nil, in: outbound, nearestTo: point)?.id, "B", "nearest to the point")
        XCTAssertNil(RouteFocusModel.pickStop(requested: nil, in: [], nearestTo: point))
    }

    func testFocusRegionFitsTheNearbyPartOfTheLine() {
        let region = RouteFocusModel.focusRegion(stop: outbound[1], shape: shape0)
        // Within 800 m of Dame Street: A, B and C but not Ongar.
        XCTAssertLessThan(region.span.latitudeDelta, 0.02)
        XCTAssertEqual(region.span.longitudeDelta, 0.0115 * 1.3, accuracy: 1e-9, "bounding box plus padding")
        XCTAssertEqual(region.center.longitude, (-6.2595 - 6.2710) / 2, accuracy: 1e-6)
        let alone = RouteFocusModel.focusRegion(stop: outbound[1], shape: nil)
        XCTAssertEqual(alone.span.latitudeDelta, 0.008, accuracy: 1e-9)
    }
}
