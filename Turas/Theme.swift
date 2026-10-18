import SwiftUI

/// The visual system: colour tokens (asset catalog, light and dark), line
/// colours, and card metrics. Views take colours from here, never literals.
enum Theme {
    // MARK: - Tokens (Assets.xcassets, light / dark)
    // Muted and late are caption text, so each keeps 4.5:1 on card and surface.

    static let brand = Color("Brand")           // #007A6C / #2BB3A0
    static let ink = Color("Ink")               // #0F2A24 / #E8F0ED
    static let surface = Color("Surface")       // #F6F8F7 / #0E1513
    static let card = Color("Card")             // #FFFFFF / #17211E
    static let muted = Color("Muted")           // #5F716C / #8FA39D
    static let late = Color("Late")             // #9C5F00 / #F0A93B
    static let cancelled = Color("Cancelled")   // #B3261E / #F2867E

    // MARK: - Line colours (same in both appearances)

    static let luasGreen = Color(hex: 0x00A651)
    static let luasRed = Color(hex: 0xE3001B)
    static let dart = Color(hex: 0x00A28C)
    static let irishRail = Color(hex: 0x00843D)

    // MARK: - Metrics

    static let cardRadius: CGFloat = 12
    static let cardSpacing: CGFloat = 6
    static let cardPadding: CGFloat = 12
    static let gutter: CGFloat = 16

    // MARK: - Derived colours

    /// Badge and line colour for a route: Luas lines, DART, other Irish
    /// Rail services, and `ink` for every bus.
    static func lineColor(mode: TransportMode, route: String) -> Color {
        switch mode {
        case .bus:
            return ink
        case .luas:
            return route == "Red" ? luasRed : luasGreen
        case .train:
            return route == "DART" ? dart : irishRail
        }
    }

    /// Text on a badge: `card` on the ink bus badge, white on coloured lines.
    static func badgeTextColor(mode: TransportMode, route: String) -> Color {
        mode == .bus ? card : .white
    }

    /// The first time's colour: brand when live (a tracked vehicle), ink
    /// when realtime (a prediction without one), muted when timetable-only,
    /// cancelled when cancelled.
    static func timeColor(for source: DepartureSource, cancelled: Bool) -> Color {
        if cancelled { return Theme.cancelled }
        switch source {
        case .live: return brand
        case .realtime: return ink
        case .timetable: return muted
        }
    }
}

extension Color {
    /// A colour from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
