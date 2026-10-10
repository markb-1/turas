import XCTest
@testable import Turas

final class ModelTests: XCTestCase {
    func testRouteRefNormalisesEmptyAgency() {
        XCTAssertNil(RouteRef(name: "39A", agencyId: "").agencyId)
        XCTAssertEqual(RouteRef(name: "39A", agencyId: ""), RouteRef(name: "39A"))
    }

    func testRouteRefMatchesVehicles() {
        let dublin = RouteRef(name: "220", agencyId: "5249")
        XCTAssertTrue(dublin.matches(routeId: "220", agencyId: "5249"))
        XCTAssertFalse(dublin.matches(routeId: "220", agencyId: "5401"), "same name, other agency")
        XCTAssertTrue(dublin.matches(routeId: "220", agencyId: nil), "unknown agency matches by name")
        XCTAssertFalse(dublin.matches(routeId: "220A", agencyId: "5249"))
        XCTAssertTrue(RouteRef(name: "220").matches(routeId: "220", agencyId: "5401"))
    }

    func testTransitRouteDecodesOlderServer() throws {
        // Before agency IDs and direction lists.
        let json = Data(#"[{"name":"39A","headsign_outbound":"Ongar"}]"#.utf8)
        let routes = try ServerJSON.decoder.decode([TransitRoute].self, from: json)
        XCTAssertEqual(routes.first?.agencyId, "")
        XCTAssertEqual(routes.first?.directions, [])
        XCTAssertEqual(routes.first?.headsign(for: 0), "Ongar")
        XCTAssertNil(routes.first?.ref.agencyId, "an empty agency is sent as no agency")
    }

    func testTransitRouteRoundTripsThroughCache() throws {
        let route = TransitRoute(name: "220", agencyId: "5401", agencyName: "Bus Éireann",
                                 headsignOutbound: "Ballincollig", directions: [0])
        let decoded = try JSONDecoder().decode(TransitRoute.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded, route)
    }

    func testEmptyHeadsignIsNil() {
        let route = TransitRoute(name: "447", agencyId: "5249", headsignOutbound: "", headsignInbound: nil)
        XCTAssertNil(route.headsign(for: 0))
        XCTAssertNil(route.headsign(for: 1))
    }
}
