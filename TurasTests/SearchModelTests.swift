import XCTest
@testable import Turas

/// A scripted PlaceSearching.
private actor FakePlaceSearch: PlaceSearching {
    private var results: [PlaceResult] = []
    private var error: Error?
    private(set) var queries: [String] = []

    func setResults(_ results: [PlaceResult]) { self.results = results }
    func setError(_ error: Error?) { self.error = error }

    func searchPlaces(_ query: String) async throws -> [PlaceResult] {
        queries.append(query)
        if let error { throw error }
        return results
    }
}

@MainActor
final class SearchModelTests: XCTestCase {
    private let clock = ManualClock()

    private func stop(_ name: String) -> StopSearchResult {
        StopSearchResult(id: "stop-\(name)", name: name, lat: 53.3, lon: -6.2, modes: [.bus])
    }

    private func route(_ name: String) -> RouteSearchResult {
        RouteSearchResult(name: name, agencyId: "1", agencyName: "Dublin Bus", mode: .bus, headsignOutbound: "Out", headsignInbound: "In")
    }

    private func place(_ name: String, lat: Double = 53.3559, lon: Double = -6.3298) -> PlaceResult {
        PlaceResult(id: "place-\(name)", name: name, subtitle: nil, lat: lat, lon: lon)
    }

    private func makeModel(source: FakeSearchSource, places: FakePlaceSearch) -> SearchModel {
        SearchModel(source: source, places: places, clock: clock.appClock)
    }

    /// Types `text`, then fires the debounce and waits for the results.
    private func type(_ text: String, into model: SearchModel, source: FakeSearchSource, expectingQueries: Int) async {
        model.query = text
        await waitUntil("debounce timer") { self.clock.sleeperCount == 1 }
        clock.advance(by: 0.25)
        await waitUntil("search \(expectingQueries)") { source.queryCount == expectingQueries && !model.isSearching }
    }

    func testEmptyQueryClearsWithoutSearching() async {
        let source = FakeSearchSource()
        let model = makeModel(source: source, places: FakePlaceSearch())
        model.query = "   "
        XCTAssertEqual(model.results, .none)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(clock.sleeperCount, 0, "no debounce timer for a blank query")
        let count = await source.queries.count
        XCTAssertEqual(count, 0)
    }

    func testTypingIsDebouncedToOneSearch() async {
        let source = FakeSearchSource()
        await source.setResponse(SearchResponse(stops: [stop("Dún Laoghaire")], routes: [route("46A")]))
        let places = FakePlaceSearch()
        await places.setResults([place("Dún Laoghaire Pier")])
        let model = makeModel(source: source, places: places)

        model.query = "d"
        model.query = "du"
        XCTAssertTrue(model.isSearching)
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 0.2)
        model.query = "dun"
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 0.25)
        await waitUntil { !model.isSearching }

        let queries = await source.queries
        XCTAssertEqual(queries, [FakeSearchSource.Query(query: "dun", mode: .bus)], "only the final text is searched")
        let placeQueries = await places.queries
        XCTAssertEqual(placeQueries, ["dun"])
        XCTAssertEqual(model.results.stops.map(\.name), ["Dún Laoghaire"])
        XCTAssertEqual(model.results.routes.map(\.name), ["46A"])
        XCTAssertEqual(model.results.places.map(\.name), ["Dún Laoghaire Pier"])
    }

    func testGroupsAreCappedAtEight() async {
        let source = FakeSearchSource()
        await source.setResponse(SearchResponse(stops: (1...10).map { stop("S\($0)") }, routes: (1...10).map { route("R\($0)") }))
        let places = FakePlaceSearch()
        await places.setResults((1...10).map { place("P\($0)") })
        let model = makeModel(source: source, places: places)

        await type("x", into: model, source: source, expectingQueries: 1)
        XCTAssertEqual(model.results.stops.count, 8)
        XCTAssertEqual(model.results.routes.count, 8)
        XCTAssertEqual(model.results.places.count, 8)
        XCTAssertEqual(model.results.stops.first?.name, "S1", "order is the server's")
    }

    func testPlacesOutsideIrelandAreDropped() async {
        let source = FakeSearchSource()
        let places = FakePlaceSearch()
        await places.setResults([
            place("London Bridge", lat: 51.5079, lon: -0.0877),
            place("Phoenix Park"),
            place("Paris", lat: 48.8566, lon: 2.3522),
        ])
        let model = makeModel(source: source, places: places)
        await type("p", into: model, source: source, expectingQueries: 1)
        XCTAssertEqual(model.results.places.map(\.name), ["Phoenix Park"])
        XCTAssertTrue(SearchModel.isInIreland(place("Belfast", lat: 54.5973, lon: -5.9301)))
        XCTAssertFalse(SearchModel.isInIreland(place("Holyhead", lat: 53.3090, lon: -4.6330)))
    }

    func testPlaceFailureStillShowsServerResults() async {
        let source = FakeSearchSource()
        await source.setResponse(SearchResponse(stops: [stop("Heuston")], routes: []))
        let places = FakePlaceSearch()
        await places.setError(URLError(.notConnectedToInternet))
        let model = makeModel(source: source, places: places)
        await type("heu", into: model, source: source, expectingQueries: 1)
        XCTAssertEqual(model.results.stops.map(\.name), ["Heuston"])
        XCTAssertEqual(model.results.places, [])
    }

    func testServerFailureStillShowsPlaces() async {
        let source = FakeSearchSource()
        await source.setError(TurasServerError.httpError(statusCode: 503))
        let places = FakePlaceSearch()
        await places.setResults([place("Phoenix Park")])
        let model = makeModel(source: source, places: places)
        await type("pho", into: model, source: source, expectingQueries: 1)
        XCTAssertEqual(model.results.stops, [])
        XCTAssertEqual(model.results.places.map(\.name), ["Phoenix Park"])
        XCTAssertFalse(model.isSearching)
    }

    func testStaleResultsAreDropped() async {
        let source = FakeSearchSource(clock: clock)
        // The first search is held on the clock for a second; the fake
        // snapshots this response when the call is made.
        await source.setDelay(.seconds(1))
        await source.setResponse(SearchResponse(stops: [stop("first")], routes: []))
        let model = makeModel(source: source, places: FakePlaceSearch())

        model.query = "a"
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 0.25)
        await waitUntil("first search in flight") { source.queryCount == 1 && self.clock.sleeperCount == 1 }

        // The newer search answers at once.
        await source.setDelay(nil)
        await source.setResponse(SearchResponse(stops: [stop("second")], routes: []))
        model.query = "ab"
        // The first answer is still held on the clock (the fake's sleep is
        // detached), plus the new debounce timer.
        await waitUntil("debounce for ab") { self.clock.sleeperCount == 2 }
        clock.advance(by: 0.25)
        await waitUntil("second answer shown") { model.results.stops.map(\.name) == ["second"] && !model.isSearching }

        // Now the first answer arrives, late.
        clock.advance(by: 1)
        await waitUntil("late answer delivered") { source.answerCount == 2 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.results.stops.map(\.name), ["second"], "the first answer arrived late and was dropped")
    }

    func testClearCancelsPendingSearch() async {
        let source = FakeSearchSource()
        let model = makeModel(source: source, places: FakePlaceSearch())
        model.query = "x"
        await waitUntil { self.clock.sleeperCount == 1 }
        model.clear()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.results, .none)
        XCTAssertFalse(model.isSearching)
        await waitUntil { self.clock.sleeperCount == 0 }
        clock.advance(by: 1)
        let count = await source.queries.count
        XCTAssertEqual(count, 0)
    }

    func testModeIsSentAndAChangeSearchesAgain() async {
        let source = FakeSearchSource()
        let model = makeModel(source: source, places: FakePlaceSearch())
        await type("39", into: model, source: source, expectingQueries: 1)
        model.setMode(.train)
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 0.25)
        await waitUntil { source.queryCount == 2 }
        let queries = await source.queries
        XCTAssertEqual(queries.map(\.mode), [.bus, .train])
        XCTAssertEqual(model.mode, .train)
    }

    func testQueryIsTrimmed() async {
        let source = FakeSearchSource()
        let model = makeModel(source: source, places: FakePlaceSearch())
        await type("  39A ", into: model, source: source, expectingQueries: 1)
        let queries = await source.queries
        XCTAssertEqual(queries.first?.query, "39A")
    }
}
