#if DEBUG
import Foundation
import MapKit

/// Canned answers for the UI smoke test (launched with TURAS_UITEST_STUB=1),
/// so it runs the same on CI without a server. Times are built from the
/// current date so rows look live. Only the paths the home screen uses are
/// known; anything else is a 404.
enum UITestStubServer {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func body(for url: URL) -> (status: Int, json: String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.path {
        case "/api/v1/nearby":
            return (200, nearby(mode: value("mode") ?? "bus"))
        case "/api/v1/search":
            return (200, search(query: value("q") ?? ""))
        case "/api/v1/stops":
            return (200, stops(route: value("route") ?? "", direction: value("direction") ?? "0"))
        case "/api/v1/vehicles":
            return (200, vehicles(mode: value("mode") ?? "bus"))
        case "/api/v1/arrivals", "/api/v1/luas/arrivals":
            return (200, arrivals(route: value("route") ?? "39A"))
        case "/api/v1/routes":
            return (200, "[]")
        default:
            return (404, #"{"error": "not stubbed"}"#)
        }
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func at(_ minutes: Int) -> String {
        formatter.string(from: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private static func time(_ minutes: Int, source: String = "live", cancelled: Bool = false) -> String {
        #"{"trip_id": "stub-\#(minutes)", "at": "\#(at(minutes))", "delay": 0, "source": "\#(source)", "cancelled": \#(cancelled)}"#
    }

    private static func nearby(mode: String) -> String {
        switch mode {
        case "luas":
            return """
            {"stops": [{"id": "LUAS-ABB", "name": "Abbey Street", "lat": 53.3485, "lon": -6.2583, "distance_m": 300}],
             "departures": [{"route": "Red", "agency_id": "10000", "direction": 0, "headsign": "Tallaght", "stop_id": "LUAS-ABB", "distance_m": 300,
                             "times": [\(time(3)), \(time(9)), \(time(15))]}]}
            """
        case "train":
            return """
            {"stops": [{"id": "IR-TARA", "name": "Tara Street", "lat": 53.3470, "lon": -6.2545, "distance_m": 350}],
             "departures": [{"route": "DART", "agency_id": "IR", "direction": 1, "headsign": "Bray", "stop_id": "IR-TARA", "distance_m": 350,
                             "times": [\(time(6)), \(time(21, source: "timetable"))]}]}
            """
        default:
            return """
            {"stops": [{"id": "8220DB000400", "name": "College Green", "lat": 53.3441, "lon": -6.2595, "distance_m": 90},
                       {"id": "8220DB000401", "name": "Dame Street", "lat": 53.3439, "lon": -6.2660, "distance_m": 420}],
             "departures": [
               {"route": "39A", "agency_id": "1", "direction": 0, "headsign": "Ongar", "stop_id": "8220DB000400", "distance_m": 90,
                "times": [\(time(2)), \(time(14, source: "realtime")), \(time(27, source: "timetable"))]},
               {"route": "16", "agency_id": "1", "direction": 1, "headsign": "Ballinteer", "stop_id": "8220DB000401", "distance_m": 420,
                "times": [\(time(5, source: "realtime", cancelled: true)), \(time(19))]},
               {"route": "46A", "agency_id": "1", "direction": 0, "stop_id": "8220DB000400", "distance_m": 90,
                "times": [\(time(8, source: "timetable"))]}
             ]}
            """
        }
    }

    private static func search(query: String) -> String {
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let stops = folded.hasPrefix("col")
            ? #"[{"id": "8220DB000400", "name": "College Green", "lat": 53.3441, "lon": -6.2595, "modes": ["bus"]}]"#
            : "[]"
        let routes = folded.hasPrefix("39")
            ? #"[{"name": "39A", "agency_id": "1", "agency_name": "Dublin Bus", "mode": "bus", "headsign_outbound": "Ongar", "headsign_inbound": "UCD Belfield"}]"#
            : "[]"
        return #"{"stops": \#(stops), "routes": \#(routes)}"#
    }

    private static func stops(route: String, direction: String) -> String {
        guard route == "39A" else { return "[]" }
        if direction == "1" {
            return """
            [{"id": "8220DB000402", "name": "Dame Street (inbound)", "lat": 53.3441, "lon": -6.2658, "seq": 1, "t": 0},
             {"id": "8220DB000403", "name": "College Green (inbound)", "lat": 53.3443, "lon": -6.2593, "seq": 2, "t": 90}]
            """
        }
        return """
        [{"id": "8220DB000400", "name": "College Green", "lat": 53.3441, "lon": -6.2595, "seq": 1, "t": 0},
         {"id": "8220DB000401", "name": "Dame Street", "lat": 53.3439, "lon": -6.2660, "seq": 2, "t": 90},
         {"id": "8220DB000405", "name": "Christchurch", "lat": 53.3434, "lon": -6.2710, "seq": 3, "t": 180}]
        """
    }

    private static func vehicles(mode: String) -> String {
        guard mode == "bus" else { return "[]" }
        return """
        [{"id": "V1", "trip_id": "stub-2", "route": "39A", "agency_id": "1", "headsign": "Ongar", "direction": 0,
          "lat": 53.3438, "lon": -6.2630, "bearing": 260, "timestamp": "\(at(0))", "mode": "bus"}]
        """
    }

    private static func arrivals(route: String) -> String {
        """
        [{"trip_id": "stub-2", "route": "\(route)", "headsign": "Ongar", "delay": 120, "predicted_arrival": "\(at(2))", "is_live": true, "is_cancelled": false},
         {"trip_id": "stub-14", "route": "\(route)", "headsign": "Ongar", "delay": 0, "predicted_arrival": "\(at(14))", "is_live": false, "is_cancelled": false},
         {"trip_id": "stub-27", "route": "\(route)", "headsign": "Ongar", "delay": 0, "predicted_arrival": "\(at(27))", "is_live": false, "is_cancelled": true}]
        """
    }

    final class StubProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (status, json) = UITestStubServer.body(for: url)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}

/// One canned place, so the smoke test's place search is hermetic.
struct UITestStubPlaceSearch: PlaceSearching {
    func searchPlaces(_ query: String) async throws -> [PlaceResult] {
        guard query.lowercased().hasPrefix("pho") else { return [] }
        return [PlaceResult(id: "phoenix", name: "Phoenix Park", subtitle: "Dublin 8", lat: 53.3559, lon: -6.3298)]
    }
}
#endif
