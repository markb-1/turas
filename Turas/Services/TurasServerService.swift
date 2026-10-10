import Foundation
import os

/// Fetches data from the Turas backend server. The server polls TFI,
/// Irish Rail and Luas, and computes arrivals from the full GTFS schedule,
/// which the app cannot bundle.
actor TurasServerService {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    private static let logger = Logger(subsystem: "com.turas", category: "TurasServerService")

    /// - Parameter session: injected by tests (a URLProtocol stub); the
    ///   default is an ephemeral session with a 10 second timeout.
    init(config: ServerConfig, session: URLSession? = nil) {
        self.baseURL = config.baseURL
        self.apiKey = config.apiKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Vehicles

    /// Fetches live vehicle positions for a transport mode.
    func fetchVehicles(mode: TransportMode) async throws -> [Vehicle] {
        let data = try await get("/api/v1/vehicles", query: [
            URLQueryItem(name: "mode", value: mode.rawValue),
        ])
        let response = try ServerJSON.decoder.decode([ServerVehicle]?.self, from: data)
        return (response ?? []).map(\.vehicle)
    }

    // MARK: - Routes and stops

    /// Fetches the routes for a mode: one entry per (agency, short name).
    func fetchRoutes(mode: TransportMode) async throws -> [TransitRoute] {
        let data = try await get("/api/v1/routes", query: [
            URLQueryItem(name: "mode", value: mode.rawValue),
        ])
        return try ServerJSON.decoder.decode([TransitRoute]?.self, from: data) ?? []
    }

    /// Fetches the ordered stops of a route in one direction. Without an
    /// agency the server uses the agency running the most trips under that
    /// short name.
    func fetchStops(route: String, agency: String?, direction: Int) async throws -> [RouteStop] {
        var query = [
            URLQueryItem(name: "route", value: route),
            URLQueryItem(name: "direction", value: String(direction)),
        ]
        if let agency, !agency.isEmpty {
            query.append(URLQueryItem(name: "agency", value: agency))
        }
        let data = try await get("/api/v1/stops", query: query)
        return try ServerJSON.decoder.decode([RouteStop]?.self, from: data) ?? []
    }

    // MARK: - Arrivals

    /// Fetches predicted arrivals for bus/train stops.
    func fetchArrivals(stopId: String, route: RouteRef, direction: Int) async throws -> [StopArrival] {
        var query = [
            URLQueryItem(name: "stop_id", value: stopId),
            URLQueryItem(name: "route", value: route.name),
            URLQueryItem(name: "direction", value: String(direction)),
        ]
        if let agency = route.agencyId {
            query.append(URLQueryItem(name: "agency", value: agency))
        }
        let data = try await get("/api/v1/arrivals", query: query)
        let response = try ServerJSON.decoder.decode([ServerStopArrival]?.self, from: data)
        return (response ?? []).map(\.stopArrival)
    }

    /// Fetches Luas arrivals (proxied by the server with a 30s cache).
    func fetchLuasArrivals(stopId: String, direction: Int, routeName: String) async throws -> [StopArrival] {
        let data = try await get("/api/v1/luas/arrivals", query: [
            URLQueryItem(name: "stop_id", value: stopId),
            URLQueryItem(name: "direction", value: String(direction)),
            URLQueryItem(name: "route", value: routeName),
        ])
        let response = try ServerJSON.decoder.decode([ServerStopArrival]?.self, from: data)
        return (response ?? []).map(\.stopArrival)
    }

    // MARK: - Private

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        guard let url = Self.makeURL(baseURL: baseURL, path: path, query: query) else {
            throw TurasServerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TurasServerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            Self.logger.error("Server returned HTTP \(httpResponse.statusCode) for \(path)")
            throw TurasServerError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    /// Builds a request URL, percent-encoding every query value, including
    /// characters URLComponents would otherwise leave alone ("+", "&", "=").
    static func makeURL(baseURL: String, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: baseURL + path) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        components.percentEncodedQueryItems = query.map { item in
            URLQueryItem(
                name: item.name,
                value: item.value?.addingPercentEncoding(withAllowedCharacters: allowed)
            )
        }
        return components.url
    }
}

// MARK: - Static data source

/// Where StaticDataStore gets routes and stops. TurasServerService in the
/// app; a fake in tests.
protocol StaticDataSource: Sendable {
    func fetchRoutes(mode: TransportMode) async throws -> [TransitRoute]
    func fetchStops(route: String, agency: String?, direction: Int) async throws -> [RouteStop]
}

extension TurasServerService: StaticDataSource {}

// MARK: - Server JSON Models

/// Matches the server's Vehicle JSON (see the server's internal/model).
struct ServerVehicle: Decodable, Equatable {
    let id: String
    let tripId: String
    let route: String
    let agencyId: String?
    let headsign: String?
    let direction: Int
    let lat: Double
    let lon: Double
    let bearing: Float?
    let timestamp: Date
    let mode: String

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case agencyId = "agency_id"
        case route, headsign, direction, lat, lon, bearing, timestamp, mode
    }

    var vehicle: Vehicle {
        Vehicle(
            id: id,
            tripId: tripId,
            routeId: route,
            agencyId: agencyId,
            headsign: headsign,
            direction: direction,
            latitude: lat,
            longitude: lon,
            bearing: bearing,
            timestamp: timestamp,
            mode: TransportMode(rawValue: mode) ?? .bus
        )
    }
}

/// Matches the server's StopArrival JSON.
struct ServerStopArrival: Decodable, Equatable {
    let tripId: String
    let route: String
    let headsign: String?
    let delay: Int
    let predictedArrival: Date
    let isLive: Bool
    let isCancelled: Bool

    enum CodingKeys: String, CodingKey {
        case tripId = "trip_id"
        case route, headsign, delay
        case predictedArrival = "predicted_arrival"
        case isLive = "is_live"
        case isCancelled = "is_cancelled"
    }

    var stopArrival: StopArrival {
        StopArrival(
            id: tripId,
            routeId: route,
            headsign: headsign,
            delay: delay,
            predictedArrival: predictedArrival,
            isLive: isLive,
            isCancelled: isCancelled
        )
    }
}

/// Matches the server's error body, {"error": "..."}.
struct ServerError: Decodable, Equatable {
    let error: String
}

/// JSON decoding shared by the server models.
enum ServerJSON {
    /// Decodes RFC 3339 dates with or without fractional seconds.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ServerJSON.parseDate(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 date, got \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    static func parseDate(_ string: String) -> Date? {
        wholeSeconds.date(from: string) ?? fractionalSeconds.date(from: string)
    }

    private static let wholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Errors

enum TurasServerError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid server URL"
        case .invalidResponse: "Invalid server response"
        case .httpError(let code): "Server error (HTTP \(code))"
        }
    }
}
