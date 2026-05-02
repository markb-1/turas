import SwiftUI

/// A lightweight map annotation showing the bus route number with a direction arrow.
///
/// When bearing data is available, a small arrow rotates to show the
/// bus's direction of travel. Bearing is in degrees clockwise from north
/// (0° = north, 90° = east, 180° = south, 270° = west).
///
/// Key SwiftUI concept: `.rotationEffect` rotates a view by an `Angle`.
/// We convert the bearing degrees to a rotation — the arrow points up
/// by default (north), so the rotation maps directly to compass bearing.
struct BusAnnotationView: View {
    let routeId: String
    let bearing: Float?
    var mode: TransportMode = .bus

    var body: some View {
        HStack(spacing: 2) {
            Text(routeId)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)

            if let bearing {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .rotationEffect(.degrees(Double(bearing)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(mode.routeColor(for: routeId), in: Capsule())
    }
}

#Preview {
    VStack(spacing: 12) {
        HStack(spacing: 12) {
            BusAnnotationView(routeId: "39A", bearing: 0)
            BusAnnotationView(routeId: "Green", bearing: 90, mode: .luas)
            BusAnnotationView(routeId: "DART", bearing: 180, mode: .train)
        }
    }
    .padding()
}
