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

    func testNearby() throws {
        let response = try ServerJSON.decoder.decode(NearbyResponse.self, from: Fixture.data("nearby"))

        // Structure the app relies on.
        XCTAssertFalse(response.departures.isEmpty)
        XCTAssertFalse(response.stops.isEmpty)
        for departure in response.departures {
            XCTAssertNotNil(response.stop(withId: departure.stopId), "every row's stop is in stops: \(departure.stopId)")
            XCTAssertLessThanOrEqual(departure.times.count, 3)
            XCTAssertEqual(departure.times.map(\.at), departure.times.map(\.at).sorted(), "times ascend")
            XCTAssertFalse(departure.id.isEmpty)
            for time in departure.times where time.cancelled {
                XCTAssertNotEqual(time.source, .live, "a cancelled time is never live")
            }
        }
        XCTAssertTrue(response.departures.contains { $0.headsign == nil }, "the fixture has a row without a headsign")
        XCTAssertTrue(response.departures.contains { $0.headsign != nil })

        // Values from the server fixture.
        let first = try XCTUnwrap(response.departures.first)
        XCTAssertEqual(first.route, "39A")
        XCTAssertEqual(first.agencyId, "5249")
        XCTAssertEqual(first.direction, 0)
        XCTAssertEqual(first.headsign, "Ongar")
        XCTAssertEqual(first.stopId, "8220DB000400")
        XCTAssertEqual(first.distanceM, 90)
        let time = try XCTUnwrap(first.times.first)
        XCTAssertEqual(time.tripId, "5913_56733")
        XCTAssertEqual(time.delay, 120)
        XCTAssertEqual(time.source, .live)
        XCTAssertFalse(time.cancelled)
        XCTAssertEqual(ServerJSON.parseDate("2026-10-10T12:02:00+01:00"), time.at, "Europe/Dublin offset")
        XCTAssertEqual(time.at, ServerJSON.parseDate("2026-10-10T11:02:00Z"))
        let stop = try XCTUnwrap(response.stop(withId: "8220DB000400"))
        XCTAssertEqual(stop.name, "College Green")
        XCTAssertEqual(stop.lat, 53.3441, accuracy: 1e-9)
        XCTAssertEqual(stop.lon, -6.2595, accuracy: 1e-9)
        XCTAssertEqual(stop.distanceM, 90)
    }

    func testSearch() throws {
        let response = try ServerJSON.decoder.decode(SearchResponse.self, from: Fixture.data("search"))

        XCTAssertFalse(response.stops.isEmpty)
        XCTAssertFalse(response.routes.isEmpty)
        for stop in response.stops {
            XCTAssertFalse(stop.modes.isEmpty, "every stop has at least one known mode")
        }

        // Values from the server fixture.
        let stop = try XCTUnwrap(response.stops.first)
        XCTAssertEqual(stop.name, "Dún Laoghaire (Mallin)")
        XCTAssertEqual(stop.modes, [.train])
        let route = try XCTUnwrap(response.routes.first)
        XCTAssertEqual(route.name, "46A")
        XCTAssertEqual(route.agencyId, "5249")
        XCTAssertEqual(route.agencyName, "Dublin Bus")
        XCTAssertEqual(route.mode, .bus)
        XCTAssertEqual(route.headsign(for: 0), "Dún Laoghaire")
        XCTAssertEqual(route.headsign(for: 1), "Phoenix Park")
        // No agency_name: the operator falls back to the agency ID.
        XCTAssertNil(response.routes[1].agencyName)
        XCTAssertEqual(response.routes[1].operatorLabel, "Operator 5401")
    }
}
