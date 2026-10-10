import SwiftUI

/// Sheet shown when the user taps a nearby stop in idle state (no route selected).
/// Displays the stop name and all routes serving it. Tapping a route selects it
/// and begins the normal route → direction → arrivals flow.
struct NearbyStopSheet: View {
    let nearbyStop: NearbyStop
    let mode: TransportMode
    let onSelectRoute: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: mode.iconName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(mode.color, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(nearbyStop.stop.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(nearbyStop.routeNames.count) route\(nearbyStop.routeNames.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Route list
            Text("Routes at this stop")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(nearbyStop.routeNames.sorted(), id: \.self) { route in
                        Button {
                            onSelectRoute(route)
                        } label: {
                            HStack {
                                Text(route)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(mode.routeColor(for: route), in: Capsule())
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AccessibilityText.route(name: route))
                        .accessibilityHint("Shows this route on the map")
                    }
                }
            }

            Spacer()
        }
        .padding(20)
    }
}
