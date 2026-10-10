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

    func testUniqueMatch() {
        let routes = ["139", "39", "39A", "46A", "Red"]
        XCTAssertEqual(MapViewModel.uniqueMatch(for: "39a", in: routes), "39A", "case-insensitive exact match")
        XCTAssertEqual(MapViewModel.uniqueMatch(for: "39", in: routes), "39", "exact match wins over partial ones")
        XCTAssertEqual(MapViewModel.uniqueMatch(for: "46", in: routes), "46A", "single partial match")
        XCTAssertEqual(MapViewModel.uniqueMatch(for: " red ", in: routes), "Red", "whitespace trimmed")
        XCTAssertNil(MapViewModel.uniqueMatch(for: "3", in: routes), "ambiguous")
        XCTAssertNil(MapViewModel.uniqueMatch(for: "", in: routes))
        XCTAssertNil(MapViewModel.uniqueMatch(for: "999", in: routes))
    }

    func testUniqueMatchRejectsDuplicateExactNames() {
        XCTAssertNil(MapViewModel.uniqueMatch(for: "220", in: ["220", "220"]))
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

    func testDirectionOptionsEmpty() {
        XCTAssertEqual(MapViewModel.directionOptions(shapeDirections: [], stopDirections: [], headsign: { _ in "x" }), [])
    }

    // MARK: - Selection

    func testRouteSelectionAccessors() {
        XCTAssertNil(RouteSelection.idle.routeName)
        XCTAssertNil(RouteSelection.idle.direction)
        XCTAssertEqual(RouteSelection.route("39A").routeName, "39A")
        XCTAssertNil(RouteSelection.route("39A").direction)
        XCTAssertEqual(RouteSelection.routeAndDirection("39A", direction: 1).routeName, "39A")
        XCTAssertEqual(RouteSelection.routeAndDirection("39A", direction: 1).direction, 1)
    }
}
