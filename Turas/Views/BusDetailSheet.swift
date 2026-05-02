import SwiftUI

/// Bottom sheet shown when a user taps a bus annotation.
/// Displays route number, vehicle ID, and last updated time.
///
/// Key SwiftUI concept: This view receives a `Vehicle` value type.
/// It doesn't need a ViewModel because it's a simple read-only display.
/// The `.sheet(item:)` modifier in ContentView presents this when
/// `selectedVehicle` is non-nil.
struct BusDetailSheet: View {
    let vehicle: Vehicle

    private var routeColor: Color { vehicle.mode.routeColor(for: vehicle.routeId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with route badge
            HStack(spacing: 12) {
                routeBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vehicle.mode.label) \(vehicle.routeId)")
                        .font(.title2.weight(.semibold))
                    if let headsign = vehicle.headsign {
                        Text("To \(headsign)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    Text("Vehicle \(vehicle.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Details
            if let headsign = vehicle.headsign {
                detailRow(icon: "arrow.right", label: "Destination", value: headsign)
            }
            detailRow(icon: "clock", label: "Last updated", value: formattedTime)

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Subviews

    private var routeBadge: some View {
        Text(vehicle.routeId)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(routeColor, in: RoundedRectangle(cornerRadius: 10))
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(routeColor)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private var formattedTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: vehicle.timestamp, relativeTo: Date())
    }
}
