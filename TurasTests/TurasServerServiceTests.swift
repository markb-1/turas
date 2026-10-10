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

    func testFetchArrivalsQuery() async throws {
        StubURLProtocol.stub.set(body: try Fixture.data("arrivals"))

        let arrivals = try await makeService().fetchArrivals(stopId: "8220DB000002", routeName: "39A", direction: 1)

        XCTAssertEqual(arrivals.count, 3)
        let url = try XCTUnwrap(StubURLProtocol.stub.recordedRequests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/arrivals")
        XCTAssertEqual(url.query, "stop_id=8220DB000002&route=39A&direction=1")
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
}
