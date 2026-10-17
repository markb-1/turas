import XCTest
@testable import Turas

final class TurasServerServiceTests: XCTestCase {
    private let config = ServerConfig(baseURL: "https://turas.test", apiKey: "test-key")

    private func makeService() -> TurasServerService {
        TurasServerService(config: config, session: StubURLProtocol.session())
    }

    func testFetchVehiclesSendsKeyAndDecodes() async throws {
        StubURLProtocol.stub.set(body: try Fixture.data("vehicles"))

        let vehicles = try await makeService().fetchVehicles(mode: .bus)

        XCTAssertEqual(vehicles.map(\.id), ["V1234", "E250"])
        let request = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://turas.test/api/v1/vehicles?mode=bus")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
    }

    // MARK: - Clock offset

    /// An HTTP Date header for `date` (RFC 1123, whole seconds, GMT).
    private func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    func testSuccessfulResponsesRecordTheServerClock() async throws {
        let offset = ServerClockOffset()
        let service = TurasServerService(config: config, session: StubURLProtocol.session(), clockOffset: offset)
        StubURLProtocol.stub.set(body: Data("[]".utf8), headers: ["Date": httpDate(Date().addingTimeInterval(120))])

        _ = try await service.fetchVehicles(mode: .bus)

        XCTAssertEqual(offset.correction, 120, accuracy: 2, "the header has 1 s resolution")
    }

    func testFailedOrUndatedResponsesRecordNothing() async throws {
        let offset = ServerClockOffset()
        let service = TurasServerService(config: config, session: StubURLProtocol.session(), clockOffset: offset)
        StubURLProtocol.stub.set(statusCode: 503, body: Data(#"{"error": "loading"}"#.utf8), headers: ["Date": httpDate(Date().addingTimeInterval(120))])
        _ = try? await service.fetchVehicles(mode: .bus)
        StubURLProtocol.stub.set(body: Data("[]".utf8), headers: ["Date": "not a date"])
        _ = try await service.fetchVehicles(mode: .bus)
        StubURLProtocol.stub.set(body: Data("[]".utf8))
        _ = try await service.fetchVehicles(mode: .bus)

        XCTAssertEqual(offset.correction, 0)
    }

    func testParsesHTTPDates() {
        XCTAssertEqual(TurasServerService.parseHTTPDate("Sat, 10 Oct 2026 11:00:00 GMT"), Date(timeIntervalSince1970: 1_791_630_000))
        XCTAssertNil(TurasServerService.parseHTTPDate("2026-10-10T11:00:00Z"))
    }

    func testFetchArrivalsQuery() async throws {
        StubURLProtocol.stub.set(body: try Fixture.data("arrivals"))

        let arrivals = try await makeService().fetchArrivals(
            stopId: "8220DB000002",
            route: RouteRef(name: "39A"),
            direction: 1
        )

        XCTAssertEqual(arrivals.count, 3)
        let url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/arrivals")
        XCTAssertEqual(url.query, "stop_id=8220DB000002&route=39A&direction=1", "no agency parameter when unknown")
    }

    func testFetchArrivalsSendsAgency() async throws {
        StubURLProtocol.stub.set(body: Data("[]".utf8))

        _ = try await makeService().fetchArrivals(
            stopId: "C1",
            route: RouteRef(name: "220", agencyId: "5401"),
            direction: 0
        )

        let url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first?.url)
        XCTAssertEqual(url.query, "stop_id=C1&route=220&direction=0&agency=5401")
    }

    func testFetchRoutes() async throws {
        StubURLProtocol.stub.set(body: try Fixture.data("routes"))

        let routes = try await makeService().fetchRoutes(mode: .bus)

        XCTAssertEqual(routes.map(\.id), ["5249|220", "5401|220", "5249|447"])
        let url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first?.url)
        XCTAssertEqual(url.absoluteString, "https://turas.test/api/v1/routes?mode=bus")
    }

    func testFetchStopsQuery() async throws {
        StubURLProtocol.stub.set(body: try Fixture.data("stops"))
        let service = makeService()

        let stops = try await service.fetchStops(route: "220", agency: "5401", direction: 0)
        XCTAssertEqual(stops.count, 2)
        var url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.last?.url)
        XCTAssertEqual(url.query, "route=220&direction=0&agency=5401")

        _ = try await service.fetchStops(route: "39A", agency: nil, direction: 1)
        url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.last?.url)
        XCTAssertEqual(url.query, "route=39A&direction=1")
    }

    func testNullBodyIsEmptyList() async throws {
        StubURLProtocol.stub.set(body: Data("null".utf8))
        let vehicles = try await makeService().fetchVehicles(mode: .luas)
        XCTAssertEqual(vehicles, [])
    }

    func testHTTPErrorIsReported() async throws {
        StubURLProtocol.stub.set(statusCode: 503, body: try Fixture.data("error"))
        do {
            _ = try await makeService().fetchVehicles(mode: .bus)
            XCTFail("expected an error")
        } catch let error as TurasServerError {
            XCTAssertEqual(error, .httpError(statusCode: 503))
        }
    }

    func testQueryValuesArePercentEncoded() throws {
        let url = try XCTUnwrap(TurasServerService.makeURL(
            baseURL: "https://turas.test",
            path: "/api/v1/stops",
            query: [URLQueryItem(name: "route", value: "A+B &C=D")]
        ))
        XCTAssertEqual(url.absoluteString, "https://turas.test/api/v1/stops?route=A%2BB%20%26C%3DD")
    }

    func testFetchNearbyQueryAndDecoding() async throws {
        StubURLProtocol.stub.set(body: Data("""
        {"stops": [{"id": "S1", "name": "College Green", "lat": 53.3441, "lon": -6.2595, "distance_m": 90}],
         "departures": []}
        """.utf8))

        let response = try await makeService().fetchNearby(lat: 53.3441, lon: -6.2595, mode: .luas)

        XCTAssertEqual(response.stops.map(\.id), ["S1"])
        let url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/nearby")
        XCTAssertEqual(url.query, "lat=53.344100&lon=-6.259500&mode=luas")
    }

    func testSearchQueryWithAndWithoutMode() async throws {
        StubURLProtocol.stub.set(body: Data(#"{"stops": [], "routes": [{"name": "39A", "agency_id": "1", "mode": "bus"}]}"#.utf8))
        let service = makeService()

        let withMode = try await service.search(query: "dún laoghaire", mode: .train)
        XCTAssertEqual(withMode.routes.map(\.name), ["39A"])
        var url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.last?.url)
        XCTAssertEqual(url.path, "/api/v1/search")
        XCTAssertEqual(url.query, "q=d%C3%BAn%20laoghaire&mode=train")

        _ = try await service.search(query: "39", mode: nil)
        url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.last?.url)
        XCTAssertEqual(url.query, "q=39", "no mode parameter when none is given")
    }

    func testFetchDeparturesQueryAndDecoding() async throws {
        StubURLProtocol.stub.set(body: Data("""
        {"stop": {"id": "8220DB000400", "name": "College Green", "code": "400", "lat": 53.3441, "lon": -6.2595, "modes": ["bus"]},
         "departures": [{"route": "39A", "agency_id": "1", "direction": 0, "headsign": "Ongar", "stop_id": "8220DB000400", "distance_m": 0,
                         "times": [{"trip_id": "t1", "at": "2026-10-12T18:52:00Z", "delay": 0, "source": "live", "cancelled": false}]}]}
        """.utf8))

        let response = try await makeService().fetchDepartures(stopId: "8220DB000400")

        XCTAssertEqual(response.stop.code, "400")
        XCTAssertEqual(response.departures.map(\.route), ["39A"])
        let url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/departures")
        XCTAssertEqual(url.query, "stop_id=8220DB000400")
        let request = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
    }

    func testFetchDepartures404IsReported() async throws {
        StubURLProtocol.stub.set(statusCode: 404, body: Data(#"{"error": "unknown stop"}"#.utf8))
        do {
            _ = try await makeService().fetchDepartures(stopId: "nope")
            XCTFail("expected an error")
        } catch let error as TurasServerError {
            XCTAssertEqual(error, .httpError(statusCode: 404))
        }
    }

    func testFetchStationsQueryAndNullBody() async throws {
        StubURLProtocol.stub.set(body: Data(#"[{"id": "8250GA00286", "name": "Dawson", "lat": 53.3402, "lon": -6.2588}]"#.utf8))
        let service = makeService()

        let stations = try await service.fetchStations(mode: .luas)
        XCTAssertEqual(stations.map(\.id), ["8250GA00286"])
        let url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/stations")
        XCTAssertEqual(url.query, "mode=luas")

        StubURLProtocol.stub.set(body: Data("null".utf8))
        let none = try await service.fetchStations(mode: .train)
        XCTAssertEqual(none, [])
    }

    func testSourceProtocolsAreSatisfiedByTheService() {
        let service = makeService()
        let nearby: NearbySource = service
        let search: SearchSource = service
        let focus: FocusSource = service
        let stop: StopSource = service
        let stations: StationSource = service
        XCTAssertTrue(nearby is TurasServerService)
        XCTAssertTrue(search is TurasServerService)
        XCTAssertTrue(focus is TurasServerService)
        XCTAssertTrue(stop is TurasServerService)
        XCTAssertTrue(stations is TurasServerService)
    }
}
