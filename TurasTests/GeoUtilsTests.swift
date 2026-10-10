import XCTest
@testable import Turas

final class GeoUtilsTests: XCTestCase {
    func testSamePointIsZero() {
        XCTAssertEqual(GeoUtils.straightLineDistance(lat1: 53.3498, lon1: -6.2603, lat2: 53.3498, lon2: -6.2603), 0, accuracy: 1e-9)
    }

    func testNorthSouthDistance() {
        // One hundredth of a degree of latitude is ~1112 m anywhere.
        let d = GeoUtils.straightLineDistance(lat1: 53.0, lon1: -6.0, lat2: 53.01, lon2: -6.0)
        XCTAssertEqual(d, 1111.95, accuracy: 0.5)
    }

    func testEastWestDistanceShrinksWithLatitude() {
        let d = GeoUtils.straightLineDistance(lat1: 53.0, lon1: -6.0, lat2: 53.0, lon2: -5.99)
        XCTAssertEqual(d, 1111.95 * cos(53 * Double.pi / 180), accuracy: 0.5)
    }

    func testSymmetric() {
        let there = GeoUtils.straightLineDistance(lat1: 53.3473, lon1: -6.2591, lat2: 53.3464, lon2: -6.2920)
        let back = GeoUtils.straightLineDistance(lat1: 53.3464, lon1: -6.2920, lat2: 53.3473, lon2: -6.2591)
        XCTAssertEqual(there, back, accuracy: 1e-9)
        // O'Connell Bridge to Heuston, roughly 2.2 km; matches the server's geo test.
        XCTAssertEqual(there, 2190, accuracy: 30)
    }
}
