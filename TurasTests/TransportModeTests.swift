import XCTest
@testable import Turas

final class TransportModeTests: XCTestCase {
    func testModeFromRawRouteId() {
        XCTAssertEqual(TransportMode.from(rawRouteId: "5242_118188"), .luas)
        XCTAssertEqual(TransportMode.from(rawRouteId: "5422_123"), .train)
        XCTAssertEqual(TransportMode.from(rawRouteId: "5249_119681"), .bus)
        XCTAssertEqual(TransportMode.from(rawRouteId: "5401_1"), .bus)
        XCTAssertEqual(TransportMode.from(rawRouteId: ""), .bus)
        // The prefix needs its underscore.
        XCTAssertEqual(TransportMode.from(rawRouteId: "5242"), .bus)
    }

    func testRawValuesMatchServerModeParameter() {
        XCTAssertEqual(TransportMode.allCases.map(\.rawValue), ["bus", "luas", "train"])
    }

    func testNearbyRadius() {
        XCTAssertEqual(TransportMode.bus.nearbyRadiusMetres, 300)
        XCTAssertEqual(TransportMode.luas.nearbyRadiusMetres, 800)
        XCTAssertEqual(TransportMode.train.nearbyRadiusMetres, 800)
    }
}
