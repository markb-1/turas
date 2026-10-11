import XCTest
@testable import Turas

final class RouteStopServiceTests: XCTestCase {
    private func stop(_ id: String, _ lat: Double, _ lon: Double, seq: Int = 1) -> RouteStop {
        RouteStop(id: id, name: "Stop \(id)", lat: lat, lon: lon, seq: seq, t: 0)
    }

    private func makeService() -> RouteStopService {
        RouteStopService(stopsByRoute: [
            "39A": [
                RouteStopDirection(direction: 0, stops: [stop("A", 53.3498, -6.2603), stop("B", 53.3520, -6.2603, seq: 2)]),
                RouteStopDirection(direction: 1, stops: [stop("B", 53.3520, -6.2603), stop("C", 53.40, -6.26, seq: 2)]),
            ],
            "46A": [
                RouteStopDirection(direction: 0, stops: [stop("A", 53.3498, -6.2603)]),
            ],
            // Two agencies share the short name: one entry per agency.
            "220": [
                RouteStopDirection(direction: 0, stops: [stop("D1", 53.39, -6.26)]),
                RouteStopDirection(direction: 0, stops: [stop("C1", 51.90, -8.47)]),
            ],
            "447": [
                RouteStopDirection(direction: 0, stops: [stop("X", 53.0, -6.0)]),
                RouteStopDirection(direction: 1, stops: [stop("Y", 53.1, -6.1)]),
            ],
        ])
    }

    func testStopsForDirectionMergesEntries() async {
        let stops = await makeService().stops(for: "220", direction: 0)
        XCTAssertEqual(stops.map(\.id), ["D1", "C1"])
    }
}
