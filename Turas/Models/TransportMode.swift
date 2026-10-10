import SwiftUI

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
