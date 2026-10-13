import SwiftUI

/// The "leaving soonest" list for one mode, with the status banner above
/// it. Minute texts tick every 30 s.
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
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LazyVStack(spacing: Theme.cardSpacing) {
                        ForEach(nearby.departures) { departure in
                            Button {
                                onSelect(departure)
                            } label: {
                                DepartureCard(
                                    departure: departure,
                                    stopName: nearby.result?.stop(withId: departure.stopId)?.name ?? "",
                                    mode: mode,
                                    now: context.date
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
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    StatusBanner(kind: .warning, message: ArrivalFormatting.updatedText(since: lastUpdated, now: context.date),
                                 actionTitle: "Retry", action: onRetry)
                }
            } else {
                StatusBanner(kind: .warning, message: message, actionTitle: "Retry", action: onRetry)
            }
        }
    }
}
