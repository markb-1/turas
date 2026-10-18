import SwiftUI

/// The "leaving soonest" list for one mode, with the status banner above
/// it. Minute texts tick every 5 s against the model's clock, and times
/// that have left drop out (`Upcoming`), so kept rows never pile up as "Due".
struct DepartureTimeline: View {
    @ObservedObject var nearby: NearbyModel
    let mode: TransportMode
    let onSelect: (NearbyDeparture) -> Void
    let onRetry: () -> Void

    /// "Nothing leaving within 300 m in the next 90 min. Try another mode
    /// or move the map." The radius is the mode's.
    nonisolated static func emptyMessage(for mode: TransportMode) -> String {
        "Nothing leaving within \(Int(mode.nearbyRadiusMetres)) m in the next 90 min. Try another mode or move the map."
    }

    var body: some View {
        VStack(spacing: Theme.cardSpacing) {
            banner
                .padding(.horizontal, Theme.gutter)
            ScrollView {
                TimelineView(.periodic(from: .now, by: DepartureFormatting.tick)) { _ in
                    let now = nearby.now()
                    LazyVStack(spacing: Theme.cardSpacing) {
                        ForEach(Upcoming.departures(nearby.departures, now: now)) { departure in
                            Button {
                                onSelect(departure)
                            } label: {
                                DepartureCard(
                                    departure: departure,
                                    stopName: nearby.result?.stop(withId: departure.stopId)?.name ?? "",
                                    mode: mode,
                                    now: now
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("timeline.row.\(departure.id)")
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, Theme.gutter)
                }
            }
            .accessibilityIdentifier("timeline.list")
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch nearby.status {
        case .loading:
            if nearby.result == nil {
                StatusBanner(kind: .progress, message: "Finding what's leaving…")
            }
        case .loaded:
            EmptyView()
        case .starting:
            StatusBanner(kind: .progress, message: "Turas is starting up…")
        case .empty:
            StatusBanner(kind: .info, message: Self.emptyMessage(for: mode))
        case .failed(let message):
            if let lastUpdated = nearby.lastUpdated {
                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    StatusBanner(kind: .warning, message: ArrivalFormatting.updatedText(since: lastUpdated, now: nearby.now()),
                                 actionTitle: "Retry", action: onRetry)
                }
            } else {
                StatusBanner(kind: .warning, message: message, actionTitle: "Retry", action: onRetry)
            }
        }
    }
}
