import SwiftUI
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

    func testRouteColorForLuasLines() {
        XCTAssertEqual(TransportMode.luas.routeColor(for: "Red"), .red)
        XCTAssertEqual(TransportMode.luas.routeColor(for: "Green"), Color(red: 0.0, green: 0.68, blue: 0.25))
        XCTAssertEqual(TransportMode.luas.routeColor(for: "Blue"), TransportMode.luas.color)
    }

    func testRouteColorForOtherModesIsModeColor() {
        XCTAssertEqual(TransportMode.bus.routeColor(for: "Red"), TransportMode.bus.color)
        XCTAssertEqual(TransportMode.train.routeColor(for: "DART"), TransportMode.train.color)
    }

    func testRawValuesMatchServerModeParameter() {
        XCTAssertEqual(TransportMode.allCases.map(\.rawValue), ["bus", "luas", "train"])
    }
}
