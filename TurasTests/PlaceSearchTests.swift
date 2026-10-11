import XCTest
@testable import Turas

/// The merge behind MapKitPlaceSearch's two requests (addresses and points
/// of interest are asked for separately; see PlaceSearchService).
final class PlaceSearchTests: XCTestCase {
    private func place(_ id: String) -> PlaceResult {
        PlaceResult(id: id, name: id, subtitle: nil, lat: 53.35, lon: -6.26)
    }

    func testAddressesComeFirstThenPointsOfInterestWithoutDuplicates() throws {
        let merged = try MapKitPlaceSearch.merge(
            addresses: .success([place("Dundrum"), place("Phoenix Park")]),
            pointsOfInterest: .success([place("Phoenix Park"), place("Phoenix Park Hotel")])
        )
        XCTAssertEqual(merged.map(\.id), ["Dundrum", "Phoenix Park", "Phoenix Park Hotel"])
    }

    func testOneFailedRequestKeepsTheOther() throws {
        let points = try MapKitPlaceSearch.merge(addresses: .failure(URLError(.timedOut)), pointsOfInterest: .success([place("Phoenix Park")]))
        XCTAssertEqual(points.map(\.id), ["Phoenix Park"])
        let addresses = try MapKitPlaceSearch.merge(addresses: .success([place("Howth")]), pointsOfInterest: .failure(URLError(.timedOut)))
        XCTAssertEqual(addresses.map(\.id), ["Howth"])
    }

    func testBothFailingThrows() {
        XCTAssertThrowsError(try MapKitPlaceSearch.merge(addresses: .failure(URLError(.timedOut)), pointsOfInterest: .failure(URLError(.cancelled))))
    }
}
