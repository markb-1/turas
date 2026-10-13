import Foundation

/// Transport modes. The server sets each route's and vehicle's mode.
enum TransportMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bus
    case luas
    case train

    var id: String { rawValue }

    /// Mode of a raw route_id in the bundled route_lookup, which predates
    /// TFI's current free-form route_ids and still uses "<agency>_<id>".
    static func from(rawRouteId: String) -> TransportMode {
        if rawRouteId.hasPrefix("5242_") { return .luas }
        if rawRouteId.hasPrefix("5422_") { return .train }
        return .bus
    }

    var label: String {
        switch self {
        case .bus: return "Bus"
        case .luas: return "Luas"
        case .train: return "Train"
        }
    }

    var iconName: String {
        switch self {
        case .bus: return "bus.fill"
        case .luas: return "tram.fill"
        case .train: return "train.side.front.car"
        }
    }

    /// How far around the map centre the timeline looks, in metres: the
    /// server's `/nearby` radius for the mode, drawn as the circle around
    /// the centre marker.
    var nearbyRadiusMetres: Double {
        switch self {
        case .bus: return 300
        case .luas, .train: return 800
        }
    }
}
