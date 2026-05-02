import CoreLocation
import Foundation
import os

/// Fetches data from the Turas backend server instead of calling TFI/Luas APIs directly.
/// The server pre-computes arrivals using the full GTFS static schedule (6.6M stop_times)
/// which the app can't bundle locally, resulting in more accurate delay predictions.
actor TurasServerService {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    private static let logger = Logger(subsystem: "com.turas", category: "TurasServerService")

    init() {
        self.baseURL = Config.turasServerURL
        self.apiKey = Config.turasServerApiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - Vehicles

    /// Fetches live vehicle positions for a transport mode from the server.
    func fetchVehicles(mode: TransportMode) async throws -> [Vehicle] {
        let url = "\(baseURL)/api/v1/vehicles?mode=\(mode.rawValue)"
        let data = try await request(url: url)
        let response = try JSONDecoder.iso8601.decode([ServerVehicle]?.self, from: data)
        return (response ?? []).map { $0.toVehicle() }
    }

    // MARK: - Arrivals

    /// Fetches predicted arrivals for bus/train stops from the server.
    func fetchArrivals(stopId: String, routeName: String, direction: Int) async throws -> [StopArrival] {
        let url = "\(baseURL)/api/v1/arrivals?stop_id=\(stopId)&route=\(routeName.urlEncoded)&direction=\(direction)"
        let data = try await request(url: url)
        let response = try JSONDecoder.iso8601.decode([ServerStopArrival]?.self, from: data)
        return (response ?? []).map { $0.toStopArrival() }
    }

    /// Fetches Luas arrivals from the server (proxied with 30s cache).
    func fetchLuasArrivals(stopId: String, direction: Int, routeName: String) async throws -> [StopArrival] {
        let url = "\(baseURL)/api/v1/luas/arrivals?stop_id=\(stopId)&direction=\(direction)&route=\(routeName.urlEncoded)"
        let data = try await request(url: url)
        let response = try JSONDecoder.iso8601.decode([ServerStopArrival]?.self, from: data)
        return (response ?? []).map { $0.toStopArrival() }
    }

    // MARK: - Private

    private func request(url urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw TurasServerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TurasServerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            Self.logger.error("Server returned HTTP \(httpResponse.statusCode) for \(urlString)")
            throw TurasServerError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }
}

// MARK: - Server JSON Models

/// Matches the JSON shape returned by the Turas server's Vehicle.
private struct ServerVehicle: Decodable {
    let id: String
    let trip_id: String
    let route: String
    let headsign: String?
    let direction: Int
    let lat: Double
    let lon: Double
    let bearing: Float?
    let timestamp: Date
    let mode: String

    func toVehicle() -> Vehicle {
        Vehicle(
            id: id,
            tripId: trip_id,
            routeId: route,
            headsign: headsign,
            direction: direction,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            bearing: bearing,
            timestamp: timestamp,
            mode: TransportMode(rawValue: mode) ?? .bus
        )
    }
}

/// Matches the JSON shape returned by the Turas server's StopArrival.
private struct ServerStopArrival: Decodable {
    let trip_id: String
    let route: String
    let headsign: String?
    let delay: Int
    let predicted_arrival: Date
    let is_live: Bool
    let is_cancelled: Bool

    func toStopArrival() -> StopArrival {
        StopArrival(
            id: trip_id,
            routeId: route,
            headsign: headsign,
            delay: delay,
            predictedArrival: predicted_arrival,
            isLive: is_live,
            isCancelled: is_cancelled
        )
    }
}

// MARK: - Errors

enum TurasServerError: LocalizedError {
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

// MARK: - Helpers

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
