import XCTest
@testable import Turas

final class NearbyModelsTests: XCTestCase {
    private let elevenUTC = Date(timeIntervalSince1970: 1_791_630_000) // 2026-10-10T11:00:00Z

    private let nearbyJSON = Data("""
    {
      "stops": [
        {"id": "8220DB000400", "name": "College Green", "lat": 53.3441, "lon": -6.2595, "distance_m": 90}
      ],
      "departures": [
        {
          "route": "39A", "agency_id": "1", "direction": 0, "headsign": "Ongar",
          "stop_id": "8220DB000400", "distance_m": 90,
          "times": [
            {"trip_id": "5913_56733", "at": "2026-10-10T12:02:00+01:00", "delay": 120, "source": "live", "cancelled": false},
            {"trip_id": "5913_56734", "at": "2026-10-10T11:14:00Z", "delay": 0, "source": "realtime", "cancelled": false},
            {"trip_id": "5913_56735", "at": "2026-10-10T11:27:00Z", "delay": 0, "source": "timetable", "cancelled": true}
          ]
        }
      ]
    }
    """.utf8)

    func testDecodesNearbyResponse() throws {
        let response = try ServerJSON.decoder.decode(NearbyResponse.self, from: nearbyJSON)

        XCTAssertEqual(response.stops, [DepartureStop(id: "8220DB000400", name: "College Green", lat: 53.3441, lon: -6.2595, distanceM: 90)])
        XCTAssertEqual(response.stop(withId: "8220DB000400")?.name, "College Green")
        XCTAssertNil(response.stop(withId: "missing"))

        let row = try XCTUnwrap(response.departures.first)
        XCTAssertEqual(row.id, "1|39A|0|Ongar")
        XCTAssertEqual(row.routeRef, RouteRef(name: "39A", agencyId: "1"))
        XCTAssertEqual(row.headsign, "Ongar")
        XCTAssertEqual(row.destination, "Ongar")
        XCTAssertEqual(row.stopId, "8220DB000400")
        XCTAssertEqual(row.distanceM, 90)
        XCTAssertEqual(row.times.count, 3)
        XCTAssertEqual(row.firstTime?.at, elevenUTC.addingTimeInterval(2 * 60), "+01:00 offset is applied")
        XCTAssertEqual(row.times[0].source, .live)
        XCTAssertEqual(row.times[0].delay, 120)
        XCTAssertEqual(row.times[1].source, .realtime)
        XCTAssertEqual(row.times[2].source, .timetable)
        XCTAssertTrue(row.times[2].cancelled)
        XCTAssertEqual(row.times[1].at, elevenUTC.addingTimeInterval(14 * 60))
    }

    func testRowIdentityIncludesHeadsign() throws {
        // The Luas splits one route and direction by destination: two rows
        // share route and direction and differ only in headsign.
        let json = Data("""
        {"stops": [], "departures": [
          {"route": "Red", "agency_id": "10000", "direction": 0, "headsign": "Tallaght", "stop_id": "L1", "distance_m": 10, "times": []},
          {"route": "Red", "agency_id": "10000", "direction": 0, "headsign": "Saggart", "stop_id": "L1", "distance_m": 10, "times": []},
          {"route": "Red", "agency_id": "10000", "direction": 1, "stop_id": "L1", "distance_m": 10, "times": []}
        ]}
        """.utf8)
        let rows = try ServerJSON.decoder.decode(NearbyResponse.self, from: json).departures
        XCTAssertEqual(rows.map(\.id), ["10000|Red|0|Tallaght", "10000|Red|0|Saggart", "10000|Red|1|"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "ForEach needs a distinct id per row")
    }

    func testDepartureSourceIsLive() {
        XCTAssertTrue(DepartureSource.live.isLive)
        XCTAssertTrue(DepartureSource.realtime.isLive)
        XCTAssertFalse(DepartureSource.timetable.isLive)
    }

    func testTolerantDecoding() throws {
        // Lists are [] on the wire, but a null or missing list must not break
        // the timeline; an unknown source reads as timetable.
        let json = Data("""
        {"stops": null, "departures": [
          {"route": "Green", "agency_id": "10000", "direction": 1, "stop_id": "L1", "distance_m": 10,
           "times": [{"trip_id": "luas-1", "at": "2026-10-10T11:05:00Z", "delay": 0, "source": "oracle"}]}
        ]}
        """.utf8)
        let response = try ServerJSON.decoder.decode(NearbyResponse.self, from: json)
        XCTAssertEqual(response.stops, [])
        XCTAssertNil(response.departures.first?.headsign, "the server omits an unknown headsign")
        XCTAssertEqual(response.departures.first?.destination, "Direction 1")
        XCTAssertEqual(response.departures.first?.times.first?.source, .timetable)
        XCTAssertEqual(response.departures.first?.times.first?.cancelled, false)

        let empty = try ServerJSON.decoder.decode(NearbyResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .empty)
    }

    func testDecodesSearchResponse() throws {
        let json = Data("""
        {
          "stops": [{"id": "S1", "name": "Dún Laoghaire (Mallin)", "lat": 53.29, "lon": -6.13, "modes": ["train", "hovercraft"]}],
          "routes": [{"name": "46A", "agency_id": "1", "agency_name": "Dublin Bus", "mode": "bus", "headsign_outbound": "Dún Laoghaire", "headsign_inbound": "Phoenix Park"},
                     {"name": "X1", "agency_id": "9", "mode": "bus"}]
        }
        """.utf8)
        let response = try ServerJSON.decoder.decode(SearchResponse.self, from: json)

        XCTAssertEqual(response.stops.first?.modes, [.train], "unknown modes are dropped")
        XCTAssertEqual(response.stops.first?.coordinate.latitude, 53.29)
        let route = try XCTUnwrap(response.routes.first)
        XCTAssertEqual(route.id, "1|46A")
        XCTAssertEqual(route.ref, RouteRef(name: "46A", agencyId: "1"))
        XCTAssertEqual(route.mode, .bus)
        XCTAssertEqual(route.headsign(for: 0), "Dún Laoghaire")
        XCTAssertEqual(route.headsign(for: 1), "Phoenix Park")
        XCTAssertEqual(route.operatorLabel, "Dublin Bus")
        XCTAssertNil(response.routes[1].headsign(for: 0))
        XCTAssertEqual(response.routes[1].operatorLabel, "Operator 9")

        let empty = try ServerJSON.decoder.decode(SearchResponse.self, from: Data("{\"stops\": [], \"routes\": null}".utf8))
        XCTAssertEqual(empty, .empty)
    }

    func testPlaceResult() {
        let place = PlaceResult(id: "p", name: "Phoenix Park", subtitle: "Dublin 8", lat: 53.3559, lon: -6.3298)
        XCTAssertEqual(place.coordinate.longitude, -6.3298)
    }
}
