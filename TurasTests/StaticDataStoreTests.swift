import XCTest
@testable import Turas

/// A scripted StaticDataSource that counts calls.
private actor FakeSource: StaticDataSource {
    private var routes: [TransportMode: [TransitRoute]] = [:]
    private var stops: [String: [RouteStop]] = [:]
    private var failing = false
    private(set) var routeFetches = 0
    private(set) var stopFetches = 0

    func setRoutes(_ routes: [TransportMode: [TransitRoute]]) { self.routes = routes }
    func setStops(_ stops: [RouteStop], route: String, agency: String?, direction: Int) {
        self.stops[Self.key(route, agency, direction)] = stops
    }
    func setFailing(_ failing: Bool) { self.failing = failing }

    func fetchRoutes(mode: TransportMode) async throws -> [TransitRoute] {
        routeFetches += 1
        if failing { throw URLError(.notConnectedToInternet) }
        return routes[mode] ?? []
    }

    func fetchStops(route: String, agency: String?, direction: Int) async throws -> [RouteStop] {
        stopFetches += 1
        if failing { throw URLError(.notConnectedToInternet) }
        return stops[Self.key(route, agency, direction)] ?? []
    }

    private static func key(_ route: String, _ agency: String?, _ direction: Int) -> String {
        "\(agency ?? "-")|\(route)|\(direction)"
    }
}

/// A clock tests can move forward.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_791_630_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += interval
    }
}

final class StaticDataStoreTests: XCTestCase {
    private var cacheDirectory: URL!
    private let clock = TestClock()

    private let db220 = TransitRoute(name: "220", agencyId: "5249", agencyName: "Dublin Bus", directions: [0, 1])
    private let be220 = TransitRoute(name: "220", agencyId: "5401", agencyName: "Bus Éireann", directions: [0])
    private let bundled39A = TransitRoute(name: "39A", agencyId: "5249")

    override func setUpWithError() throws {
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaticDataStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func stop(_ id: String) -> RouteStop {
        RouteStop(id: id, name: id, lat: 53, lon: -6, seq: 1, t: 0)
    }

    private func makeStore(source: FakeSource, bundledStops: RouteStopService = RouteStopService(stopsByRoute: [:])) -> StaticDataStore {
        let clock = clock
        let bundled = bundled39A
        return StaticDataStore(
            source: source,
            bundledStops: bundledStops,
            cacheDirectory: cacheDirectory,
            now: { clock.now },
            bundledRoutes: { [.bus: [bundled]] }
        )
    }

    // MARK: - Routes

    func testRoutesFallBackToBundledWithoutCache() async {
        let store = makeStore(source: FakeSource())
        let routes = await store.routes(for: .bus)
        let luas = await store.routes(for: .luas)
        XCTAssertEqual(routes, [bundled39A])
        XCTAssertEqual(luas, [])
    }

    func testRefreshFetchesCachesAndServesFromCache() async {
        let source = FakeSource()
        await source.setRoutes([.bus: [db220, be220]])

        let store = makeStore(source: source)
        let changed = await store.refreshRoutesIfStale()
        let routes = await store.routes(for: .bus)
        XCTAssertEqual(changed, [.bus], "luas and train returned nothing, so they keep their data")
        XCTAssertEqual(routes, [db220, be220])
        let firstFetches = await source.routeFetches
        XCTAssertEqual(firstFetches, 3, "one fetch per mode")

        // A new store (next launch) reads the fresh cache without the network.
        let relaunched = makeStore(source: source)
        let cached = await relaunched.routes(for: .bus)
        _ = await relaunched.refreshRoutesIfStale()
        XCTAssertEqual(cached, [db220, be220])
        let fetchesAfterRelaunch = await source.routeFetches
        XCTAssertEqual(fetchesAfterRelaunch, 5, "only the two modes without a cache are fetched again")
    }

    func testStaleCacheIsRefetched() async {
        let source = FakeSource()
        await source.setRoutes([.bus: [db220]])
        let store = makeStore(source: source)
        await store.refreshRoutesIfStale()

        clock.advance(by: StaticDataStore.maxAge + 60)
        await source.setRoutes([.bus: [db220, be220]])
        let relaunched = makeStore(source: source)
        let changed = await relaunched.refreshRoutesIfStale()
        let routes = await relaunched.routes(for: .bus)

        XCTAssertTrue(changed.contains(.bus))
        XCTAssertEqual(routes, [db220, be220])
    }

    func testRefreshFailureKeepsCachedRoutes() async {
        let source = FakeSource()
        await source.setRoutes([.bus: [db220]])
        await makeStore(source: source).refreshRoutesIfStale()

        clock.advance(by: StaticDataStore.maxAge + 60)
        await source.setFailing(true)
        let relaunched = makeStore(source: source)
        let changed = await relaunched.refreshRoutesIfStale()
        let routes = await relaunched.routes(for: .bus)

        XCTAssertEqual(changed, [])
        XCTAssertEqual(routes, [db220], "a stale cache beats the bundled list")
    }

    // MARK: - Stops

    func testStopsFromServerAreCached() async {
        let source = FakeSource()
        await source.setStops([stop("C1"), stop("C2")], route: "220", agency: "5401", direction: 0)
        let store = makeStore(source: source)

        let first = await store.stops(for: be220.ref, direction: 0)
        let second = await store.stops(for: be220.ref, direction: 0)
        XCTAssertEqual(first.map(\.id), ["C1", "C2"])
        XCTAssertEqual(second, first)
        let fetches = await source.stopFetches
        XCTAssertEqual(fetches, 1)

        // Next launch, offline: the disk cache still answers.
        await source.setFailing(true)
        let relaunched = makeStore(source: source)
        let cached = await relaunched.stops(for: be220.ref, direction: 0)
        XCTAssertEqual(cached.map(\.id), ["C1", "C2"])
    }

    func testStaleStopsUsedWhenOffline() async {
        let source = FakeSource()
        await source.setStops([stop("C1")], route: "220", agency: "5401", direction: 0)
        _ = await makeStore(source: source).stops(for: be220.ref, direction: 0)

        clock.advance(by: StaticDataStore.maxAge + 60)
        await source.setFailing(true)
        let stops = await makeStore(source: source).stops(for: be220.ref, direction: 0)
        XCTAssertEqual(stops.map(\.id), ["C1"])
    }

    func testStopsFallBackToBundled() async {
        let source = FakeSource()
        await source.setFailing(true)
        let bundledStops = RouteStopService(stopsByRoute: [
            "39A": [RouteStopDirection(direction: 1, stops: [stop("B1"), stop("B2")])],
        ])
        let store = makeStore(source: source, bundledStops: bundledStops)

        let stops = await store.stops(for: RouteRef(name: "39A", agencyId: "5249"), direction: 1)
        XCTAssertEqual(stops.map(\.id), ["B1", "B2"])
    }

    // MARK: - Resolving shared names

    func testResolvePicksAgencyServingTheStop() async {
        let source = FakeSource()
        await source.setRoutes([.bus: [db220, be220]])
        await source.setStops([stop("D1"), stop("D2")], route: "220", agency: "5249", direction: 0)
        await source.setStops([stop("D2"), stop("D1")], route: "220", agency: "5249", direction: 1)
        await source.setStops([stop("C1"), stop("C2")], route: "220", agency: "5401", direction: 0)
        let store = makeStore(source: source)
        await store.refreshRoutesIfStale()

        let cork = await store.resolve(name: "220", mode: .bus, atStop: "C2")
        let dublin = await store.resolve(name: "220", mode: .bus, atStop: "D1")
        let unknown = await store.resolve(name: "220", mode: .bus, atStop: "Z")
        let unique = await store.resolve(name: "39A", mode: .bus, atStop: "Z")

        XCTAssertEqual(cork, be220.ref)
        XCTAssertEqual(dublin, db220.ref)
        XCTAssertEqual(unknown, RouteRef(name: "220"), "undecidable: let the server choose")
        XCTAssertEqual(unique, RouteRef(name: "39A"), "39A is not in the refreshed list")
    }

    // MARK: - Bundled lists

    func testMakeRouteListsLeavesAgencyToServer() {
        let lists = StaticDataStore.makeRouteLists(
            routeLookup: [
                "5249_1": "220", "5249_2": "220", "5401_9": "220",
                "5242_3": "Green", "5422_4": "DART", "5249_5": "",
            ],
            headsigns: ["220_0": "Lady's Well", "Green_1": "Broombridge"]
        )
        // Bundled prefixes are not current agency IDs: one 220, no agency.
        XCTAssertEqual(lists[.bus]?.map(\.id), ["|220"])
        XCTAssertNil(lists[.bus]?.first?.ref.agencyId)
        XCTAssertEqual(lists[.bus]?.first?.headsign(for: 0), "Lady's Well")
        XCTAssertEqual(lists[.luas]?.first?.headsign(for: 1), "Broombridge")
        XCTAssertEqual(lists[.train]?.map(\.name), ["DART"])
    }

    func testCacheFileNamesAreSafe() {
        XCTAssertEqual(StaticDataStore.routesFile(.bus), "routes-bus.json")
        XCTAssertEqual(StaticDataStore.stopsFile(RouteRef(name: "220", agencyId: "5401"), 0), "stops-5401-220-0.json")
        XCTAssertEqual(StaticDataStore.stopsFile(RouteRef(name: "A/B"), 1), "stops-default-A%2FB-1.json")
    }
}
