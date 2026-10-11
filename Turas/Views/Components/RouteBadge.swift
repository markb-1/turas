import SwiftUI

/// The route's pill: ink for buses, the line colour for Luas and rail.
struct RouteBadge: View {
    let route: String
    let mode: TransportMode

    var body: some View {
        Text(route)
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(Theme.badgeTextColor(mode: mode, route: route))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.lineColor(mode: mode, route: route), in: Capsule())
            .accessibilityHidden(true) // The row carries one label.
    }
}

#Preview {
    HStack {
        RouteBadge(route: "39A", mode: .bus)
        RouteBadge(route: "Green", mode: .luas)
        RouteBadge(route: "Red", mode: .luas)
        RouteBadge(route: "DART", mode: .train)
    }
    .padding()
}
