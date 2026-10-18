import XCTest
@testable import Turas

final class StopModelsTests: XCTestCase {
    /// The spec's /departures example.
    private let departuresJSON = Data("""
    {
      "stop": {"id": "8220DB000400", "name": "College Green", "code": "400", "lat": 53.3441, "lon": -6.2595, "modes": ["bus"]},
      "departures": [
        {"route": "39A", "agency_id": "1", "direction": 0, "headsign": "Ongar", "stop_id": "8220DB000400", "distance_m": 0,
         "times": [{"trip_id": "5913_56733", "at": "2026-10-12T19:52:00+01:00", "delay": 120, "source": "live", "cancelled": false}]}
      ]
    }
    """.utf8)

    func testDecodesStopDepartures() throws {
        let response = try ServerJSON.decoder.decode(StopDepartures.self, from: departuresJSON)

        XCTAssertEqual(response.stop, StopInfo(id: "8220DB000400", name: "College Green", code: "400", lat: 53.3441, lon: -6.2595, modes: [.bus]))
        let row = try XCTUnwrap(response.departures.first)
        XCTAssertEqual(row.id, "1|39A|0|Ongar")
        XCTAssertEqual(row.stopId, "8220DB000400")
        XCTAssertEqual(row.distanceM, 0)
        XCTAssertEqual(row.firstTime?.at, ServerJSON.parseDate("2026-10-12T18:52:00Z"), "the +01:00 offset is applied")
        XCTAssertEqual(row.firstTime?.source, .live)
        XCTAssertEqual(row.firstTime?.delay, 120)
    }

    func testTolerantStopDecoding() throws {
        // No code (the server omits an empty one), an unknown mode, no departures list.
        let json = Data(#"{"stop": {"id": "L1", "name": "Abbey Street", "lat": 53.3485, "lon": -6.2583, "modes": ["luas", "hovercraft"]}}"#.utf8)
        let response = try ServerJSON.decoder.decode(StopDepartures.self, from: json)
        XCTAssertNil(response.stop.code)
        XCTAssertEqual(response.stop.modes, [.luas])
        XCTAssertEqual(response.departures, [])

        let emptyCode = Data(#"{"stop": {"id": "L1", "name": "X", "code": "", "lat": 1, "lon": 2}, "departures": null}"#.utf8)
        let decoded = try ServerJSON.decoder.decode(StopDepartures.self, from: emptyCode)
        XCTAssertNil(decoded.stop.code, "an empty code reads as none")
        XCTAssertEqual(decoded.stop.modes, [])
        XCTAssertEqual(decoded.departures, [])
    }

    func testDeparturesStopWithoutCodeDecodesToNil() throws {
        let json = Data("""
        {"stop": {"id": "8220DB000400", "name": "College Green", "lat": 53.3441, "lon": -6.2595, "modes": ["bus"]},
         "departures": [{"route": "39A", "agency_id": "1", "direction": 0, "stop_id": "8220DB000400", "distance_m": 0, "times": []}]}
        """.utf8)
        let response = try ServerJSON.decoder.decode(StopDepartures.self, from: json)
        XCTAssertNil(response.stop.code)
        XCTAssertEqual(response.departures.count, 1)
    }

    func testDecodesStations() throws {
        let json = Data(#"[{"id": "8250GA00286", "name": "Dawson", "lat": 53.3402, "lon": -6.2588}]"#.utf8)
        let stations = try ServerJSON.decoder.decode([Station].self, from: json)
        XCTAssertEqual(stations, [Station(id: "8250GA00286", name: "Dawson", lat: 53.3402, lon: -6.2588)])
        XCTAssertEqual(stations[0].coordinate.longitude, -6.2588)
    }

    func testStopTargetFromPinStationAndSearchResult() {
        let pin = StopTarget(DepartureStop(id: "B1", name: "College Green", lat: 53.3441, lon: -6.2595, distanceM: 90), mode: .bus)
        XCTAssertEqual(pin, StopTarget(id: "B1", name: "College Green", lat: 53.3441, lon: -6.2595, mode: .bus))
        XCTAssertEqual(pin.coordinate.latitude, 53.3441)

        let station = StopTarget(Station(id: "L1", name: "Abbey Street", lat: 53.3485, lon: -6.2583), mode: .luas)
        XCTAssertEqual(station.mode, .luas)
        XCTAssertEqual(station.name, "Abbey Street")
        XCTAssertEqual(station.id, "L1")

        let train = StopSearchResult(id: "T1", name: "Tara Street", lat: 53.3470, lon: -6.2545, modes: [.train])
        XCTAssertEqual(StopTarget(train, preferring: .bus).mode, .train, "a stop that does not serve the tab's mode uses its own")
        let both = StopSearchResult(id: "D1", name: "Dún Laoghaire", lat: 53.294, lon: -6.134, modes: [.bus, .luas])
        XCTAssertEqual(StopTarget(both, preferring: .luas).mode, .luas, "the tab's mode when the stop serves it")
        XCTAssertEqual(StopTarget(both, preferring: .train).mode, .bus, "else the stop's first mode")
        let none = StopSearchResult(id: "N1", name: "X", lat: 0, lon: 0, modes: [])
        XCTAssertEqual(StopTarget(none, preferring: .train).mode, .train, "no modes listed: the tab's")
    }
}
