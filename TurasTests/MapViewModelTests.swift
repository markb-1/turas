import XCTest
@testable import Turas

final class MapViewModelTests: XCTestCase {
    // MARK: - Error messages

    func testUserFriendlyErrorForHTTPStatus() {
        let cases: [(Int, String)] = [
            (401, "API key issue. Check configuration."),
            (403, "API key issue. Check configuration."),
            (429, "Too many requests. Retrying..."),
            (503, "Server is starting up. Retrying..."),
            (500, "Service temporarily unavailable. Retrying..."),
            (502, "Service temporarily unavailable. Retrying..."),
            (404, "Network error (404). Check your connection."),
        ]
        for (code, message) in cases {
            XCTAssertEqual(MapViewModel.userFriendlyError(TurasServerError.httpError(statusCode: code)), message, "HTTP \(code)")
        }
    }

    func testUserFriendlyErrorForOtherErrors() {
        XCTAssertEqual(MapViewModel.userFriendlyError(TurasServerError.invalidURL), "Server error. Retrying...")
        XCTAssertEqual(MapViewModel.userFriendlyError(TurasServerError.invalidResponse), "Server error. Retrying...")
        XCTAssertEqual(MapViewModel.userFriendlyError(URLError(.notConnectedToInternet)), "No internet connection. Check your network.")
        XCTAssertEqual(MapViewModel.userFriendlyError(NSError(domain: "other", code: 1)), "Something went wrong. Retrying...")
    }

    func testIsCancellation() {
        XCTAssertTrue(MapViewModel.isCancellation(CancellationError()))
        XCTAssertTrue(MapViewModel.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(MapViewModel.isCancellation(URLError(.timedOut)))
    }

    // MARK: - Search

    private func route(_ name: String, _ agency: String = "5249") -> TransitRoute {
        TransitRoute(name: name, agencyId: agency)
    }

    func testUniqueMatch() {
        let routes = [route("139"), route("39"), route("39A"), route("46A"), route("Red", "5242")]
        XCTAssertEqual(MapViewModel.uniqueMatch(for: "39a", in: routes)?.name, "39A", "case-insensitive exact match")
        XCTAssertEqual(MapViewModel.uniqueMatch(for: "39", in: routes)?.name, "39", "exact match wins over partial ones")
        XCTAssertEqual(MapViewModel.uniqueMatch(for: "46", in: routes)?.name, "46A", "single partial match")
        XCTAssertEqual(MapViewModel.uniqueMatch(for: " red ", in: routes)?.name, "Red", "whitespace trimmed")
        XCTAssertNil(MapViewModel.uniqueMatch(for: "3", in: routes), "ambiguous")
        XCTAssertNil(MapViewModel.uniqueMatch(for: "", in: routes))
        XCTAssertNil(MapViewModel.uniqueMatch(for: "999", in: routes))
    }

    func testUniqueMatchWithTwoAgenciesStaysInSearch() {
        let routes = [route("220", "5249"), route("220", "5401"), route("220A")]
        XCTAssertNil(MapViewModel.uniqueMatch(for: "220", in: routes))
        XCTAssertEqual(MapViewModel.uniqueMatch(for: "220a", in: routes)?.agencyId, "5249")
    }

    func testTransitRouteLookup() {
        let routes = [route("220", "5249"), route("220", "5401"), route("39A")]
        XCTAssertEqual(MapViewModel.transitRoute(for: RouteRef(name: "220", agencyId: "5401"), in: routes)?.agencyId, "5401")
        XCTAssertNil(MapViewModel.transitRoute(for: RouteRef(name: "220"), in: routes), "ambiguous without agency")
        XCTAssertEqual(MapViewModel.transitRoute(for: RouteRef(name: "39A"), in: routes)?.name, "39A")
        XCTAssertNil(MapViewModel.transitRoute(for: RouteRef(name: "220", agencyId: "9999"), in: routes))
    }

    // MARK: - Directions

    func testDirectionOptionsUnionShapesAndStops() {
        let options = MapViewModel.directionOptions(
            shapeDirections: [0],
            stopDirections: [0, 1],
            headsign: { $0 == 0 ? "Ongar" : nil }
        )
        XCTAssertEqual(options.map(\.direction), [0, 1])
        XCTAssertEqual(options.map(\.title), ["To Ongar", "Direction 1"])
    }

    func testDirectionOptionsForRouteWithoutShapes() {
        // Routes 447 and 448 have stops but no shapes.
        let options = MapViewModel.directionOptions(shapeDirections: [], stopDirections: [0, 1], headsign: { _ in nil })
        XCTAssertEqual(options.map(\.title), ["Direction 0", "Direction 1"])
    }

    func testDirectionOptionsFallBackToBothDirections() {
        XCTAssertEqual(
            MapViewModel.directionOptions(shapeDirections: [], stopDirections: [], headsign: { _ in nil }).map(\.direction),
            [0, 1]
        )
    }

    // MARK: - Selection

    func testRouteSelectionAccessors() {
        let route = RouteRef(name: "39A", agencyId: "5249")
        XCTAssertNil(RouteSelection.idle.route)
        XCTAssertNil(RouteSelection.idle.direction)
        XCTAssertEqual(RouteSelection.route(route).route, route)
        XCTAssertEqual(RouteSelection.route(route).routeName, "39A")
        XCTAssertNil(RouteSelection.route(route).direction)
        XCTAssertEqual(RouteSelection.routeAndDirection(route, direction: 1).route, route)
        XCTAssertEqual(RouteSelection.routeAndDirection(route, direction: 1).direction, 1)
    }
}
