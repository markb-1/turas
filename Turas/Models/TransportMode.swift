import SwiftUI

/// Transport modes derived from the GTFS agency prefix in a raw route_id.
enum TransportMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bus
    case luas
    case train

    var id: String { rawValue }

    /// Determines transport mode from the raw GTFS route_id agency prefix.
    static func from(rawRouteId: String) -> TransportMode {
        if rawRouteId.hasPrefix("5242_") { return .luas }
        if rawRouteId.hasPrefix("5422_") { return .train }
        return .bus
    }

    /// The agency prefix of a raw GTFS route_id ("5249_119681" -> "5249"),
    /// or nil when it has none.
    static func agencyId(fromRawRouteId rawRouteId: String) -> String? {
        guard let underscore = rawRouteId.firstIndex(of: "_"), underscore != rawRouteId.startIndex else {
            return nil
        }
        return String(rawRouteId[..<underscore])
    }

    var label: String {
        switch self {
        case .bus: return "Bus"
        case .luas: return "Luas"
        case .train: return "Train"
        }
    }

    /// Default mode color (used for mode tabs and fallback).
    var color: Color {
        switch self {
        case .bus: return .blue
        case .luas: return .purple
        case .train: return .green
        }
    }

    /// Route-specific color — Luas Red/Green lines get their own colours.
    func routeColor(for routeName: String) -> Color {
        guard self == .luas else { return color }
        switch routeName {
        case "Red": return .red
        case "Green": return Color(red: 0.0, green: 0.68, blue: 0.25)
        default: return color
        }
    }

    var iconName: String {
        switch self {
        case .bus: return "bus.fill"
        case .luas: return "tram.fill"
        case .train: return "train.side.front.car"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .bus: return "Route number"
        case .luas: return "Line name"
        case .train: return "Service name"
        }
    }
}
