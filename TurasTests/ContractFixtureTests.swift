import XCTest
@testable import Turas

/// Decodes the golden JSON produced by the server's TestContractFixtures
/// (turas-server/testdata/contract). The files in Fixtures/ must stay
/// byte-identical to the server's copies.
final class ContractFixtureTests: XCTestCase {
    private let elevenUTC = Date(timeIntervalSince1970: 1_791_630_000) // 2026-10-10T11:00:00Z

    func testVehicles() throws {
        let vehicles = try ServerJSON.decoder.decode([ServerVehicle].self, from: Fixture.data("vehicles"))
            .map(\.vehicle)
        XCTAssertEqual(vehicles.count, 2)

        let bus = vehicles[0]
        XCTAssertEqual(bus.id, "V1234")
        XCTAssertEqual(bus.tripId, "5249_12345_1_0")
        XCTAssertEqual(bus.routeId, "39A")
        XCTAssertEqual(bus.agencyId, "5249")
        XCTAssertEqual(bus.headsign, "Ongar")
        XCTAssertEqual(bus.direction, 0)
        XCTAssertEqual(bus.latitude, 53.349806, accuracy: 1e-9)
        XCTAssertEqual(bus.longitude, -6.26031, accuracy: 1e-9)
        XCTAssertEqual(bus.bearing, 147.5)
        XCTAssertEqual(bus.timestamp, elevenUTC)
        XCTAssertEqual(bus.mode, .bus)

        let train = vehicles[1]
        XCTAssertEqual(train.id, "E250")
        XCTAssertEqual(train.routeId, "DART")
        XCTAssertEqual(train.agencyId, "5422")
        XCTAssertEqual(train.direction, 1)
        XCTAssertNil(train.headsign, "omitted when empty")
        XCTAssertNil(train.bearing, "omitted when unknown")
        XCTAssertEqual(train.mode, .train)
    }

    func testArrivals() throws {
        let arrivals = try ServerJSON.decoder.decode([ServerStopArrival].self, from: Fixture.data("arrivals"))
            .map(\.stopArrival)
        XCTAssertEqual(arrivals.count, 3)

        XCTAssertEqual(arrivals[0], StopArrival(
            id: "5249_12345_1_0", routeId: "39A", headsign: "Ongar", delay: 120,
            predictedArrival: elevenUTC.addingTimeInterval(4 * 60), isLive: true, isCancelled: false
        ))
        XCTAssertFalse(arrivals[1].isLive, "scheduled (ghost) arrival")
        XCTAssertEqual(arrivals[1].predictedArrival, elevenUTC.addingTimeInterval(19 * 60))
        XCTAssertTrue(arrivals[2].isCancelled)
        XCTAssertNil(arrivals[2].headsign)
        XCTAssertEqual(arrivals[2].predictedArrival, elevenUTC.addingTimeInterval(34 * 60))
    }

    func testRoutes() throws {
        let routes = try ServerJSON.decoder.decode([TransitRoute].self, from: Fixture.data("routes"))
        XCTAssertEqual(routes.count, 3)

        XCTAssertEqual(routes[0], TransitRoute(
            name: "220", agencyId: "5249", agencyName: "Dublin Bus",
            headsignOutbound: "Lady's Well", headsignInbound: "Ballymun", directions: [0, 1]
        ))
        XCTAssertEqual(routes[1].agencyName, "Bus Éireann")
        XCTAssertNil(routes[1].headsignInbound, "omitted when empty")
        XCTAssertEqual(routes[1].directions, [0])
        XCTAssertNil(routes[2].agencyName)
        XCTAssertEqual(routes[2].directions, [], "a route with no stops")
        XCTAssertEqual(routes[2].operatorLabel, "Operator 5249")
    }

    func testStops() throws {
        let stops = try ServerJSON.decoder.decode([RouteStop].self, from: Fixture.data("stops"))
        XCTAssertEqual(stops.map(\.id), ["8220DB000002", "8250GA00286"])
        XCTAssertEqual(stops[1].seq, 2)
        XCTAssertEqual(stops[1].t, 95)
        XCTAssertEqual(stops[0].lat, 53.352241, accuracy: 1e-9)
    }

    func testError() throws {
        let error = try ServerJSON.decoder.decode(ServerError.self, from: Fixture.data("error"))
        XCTAssertFalse(error.error.isEmpty)
    }

    func testDatesWithAndWithoutFractionalSecondsOrOffsets() {
        XCTAssertEqual(ServerJSON.parseDate("2026-10-10T11:00:00Z"), elevenUTC)
        XCTAssertEqual(ServerJSON.parseDate("2026-10-10T12:00:00+01:00"), elevenUTC)
        let fractional = ServerJSON.parseDate("2026-10-10T11:00:00.250Z")
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, elevenUTC.timeIntervalSince1970 + 0.25, accuracy: 0.001)
        XCTAssertNil(ServerJSON.parseDate("10 Oct 2026"))
    }
}
