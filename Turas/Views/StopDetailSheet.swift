import SwiftUI

/// Bottom sheet shown when a user taps a stop annotation.
/// Fetches real-time arrival predictions — Luas uses the Luas Forecast API,
/// buses and trains use TFI GTFS-RT TripUpdates.
///
/// Arrivals matched to a live vehicle show in the mode's colour with a mode icon.
/// "Ghost" vehicles (no matching live vehicle) show in grey with a clock icon.
struct StopDetailSheet: View {
    let stop: RouteStop
    let routeName: String
    let direction: Int
    let mode: TransportMode
    let serverService: TurasServerService

    @State private var arrivals: [StopArrival] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var routeColor: Color { mode.routeColor(for: routeName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: mode.iconName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(routeColor, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name)
                        .font(.title2.weight(.semibold))
                    Text("\(mode.label) \(routeName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Arrivals
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading arrivals...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if arrivals.isEmpty {
                Label("No upcoming arrivals", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(arrivals.prefix(5)) { arrival in
                    arrivalRow(arrival)
                }
            }

            Spacer()
        }
        .padding(20)
        .task {
            await fetchArrivals()
        }
    }

    private func arrivalRow(_ arrival: StopArrival) -> some View {
        HStack(spacing: 10) {
            // Status indicator
            Image(systemName: arrival.isCancelled ? "xmark.circle.fill" :
                              arrival.isLive ? mode.iconName : "clock")
                .font(.caption)
                .foregroundStyle(arrival.isCancelled ? .red :
                                 arrival.isLive ? routeColor : .gray)
                .frame(width: 20)

            // Destination
            VStack(alignment: .leading, spacing: 2) {
                if let headsign = arrival.headsign {
                    Text("To \(headsign)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(arrival.isCancelled ? .secondary :
                                         .primary)
                        .strikethrough(arrival.isCancelled)
                }
                if arrival.isCancelled {
                    Text("Cancelled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else if arrival.delay > 60 {
                    Text("+\(arrival.delay / 60) min late")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Arrival time
            Text(formattedArrivalTime(arrival.predictedArrival))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(arrival.isCancelled ? .red :
                                 arrival.isLive ? routeColor : .gray)
                .strikethrough(arrival.isCancelled)
        }
    }

    private func formattedArrivalTime(_ date: Date) -> String {
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes < 1 { return "Due" }
        if minutes == 1 { return "1 min" }
        return "\(minutes) mins"
    }

    private func fetchArrivals() async {
        do {
            if mode == .luas {
                arrivals = try await serverService.fetchLuasArrivals(
                    stopId: stop.id,
                    direction: direction,
                    routeName: routeName
                )
            } else {
                arrivals = try await serverService.fetchArrivals(
                    stopId: stop.id,
                    routeName: routeName,
                    direction: direction
                )
            }
        } catch {
            errorMessage = "Unable to load arrivals: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
