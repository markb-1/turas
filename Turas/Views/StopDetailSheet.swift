import SwiftUI

/// Bottom sheet shown when a user taps a stop annotation.
/// Fetches real-time arrival predictions — Luas uses the Luas Forecast API,
/// buses and trains use TFI GTFS-RT TripUpdates (both via the server).
///
/// While the sheet is open it refreshes every 30 seconds; pull down to
/// refresh sooner. Arrivals with a live vehicle show in the route's colour
/// with a mode icon; scheduled ("ghost") arrivals show in grey with a clock.
struct StopDetailSheet: View {
    let stop: RouteStop
    let route: RouteRef
    let direction: Int
    let mode: TransportMode
    let serverService: TurasServerService

    @State private var arrivals: [StopArrival] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?

    private static let refreshInterval: Duration = .seconds(30)

    private var routeColor: Color { mode.routeColor(for: route.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Divider()

                arrivalsSection

                if let lastUpdated {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ArrivalFormatting.updatedText(since: lastUpdated, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable {
            await fetchArrivals()
        }
        .task {
            await refreshPeriodically()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: mode.iconName)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(routeColor, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(mode.label) \(route.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var arrivalsSection: some View {
        if isLoading && arrivals.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading arrivals...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if arrivals.isEmpty {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("No upcoming arrivals", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(arrivals.prefix(5)) { arrival in
                arrivalRow(arrival)
            }
            if errorMessage != nil {
                // Keep showing the last good arrivals; say the refresh failed.
                Label("Couldn't refresh. Showing the last arrivals.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Text(ArrivalFormatting.minutesText(until: arrival.predictedArrival))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(arrival.isCancelled ? .red :
                                 arrival.isLive ? routeColor : .gray)
                .strikethrough(arrival.isCancelled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.arrival(arrival))
    }

    // MARK: - Loading

    /// Fetches now and then every 30 seconds until the sheet goes away
    /// (SwiftUI cancels the task on dismissal).
    private func refreshPeriodically() async {
        while !Task.isCancelled {
            await fetchArrivals()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    private func fetchArrivals() async {
        do {
            let result: [StopArrival]
            if mode == .luas {
                result = try await serverService.fetchLuasArrivals(
                    stopId: stop.id,
                    direction: direction,
                    routeName: route.name
                )
            } else {
                result = try await serverService.fetchArrivals(
                    stopId: stop.id,
                    route: route,
                    direction: direction
                )
            }
            arrivals = result
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            if !MapViewModel.isCancellation(error) {
                errorMessage = "Unable to load arrivals: \(error.localizedDescription)"
            }
        }
        isLoading = false
    }
}
