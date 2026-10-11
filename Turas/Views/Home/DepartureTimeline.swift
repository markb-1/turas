import SwiftUI

/// The "leaving soonest" list for one mode, with the status banner above
/// it. Minute texts tick every 30 s; a pin tap scrolls to a row.
struct DepartureTimeline: View {
    @ObservedObject var nearby: NearbyModel
    let mode: TransportMode
    @Binding var scrollToRow: String?
    let onSelect: (NearbyDeparture) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Theme.cardSpacing) {
            banner
                .padding(.horizontal, Theme.gutter)
            ScrollViewReader { proxy in
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
                                .id(departure.id)
                            }
                        }
                        .padding(.horizontal, Theme.gutter)
                        .padding(.bottom, Theme.gutter)
                    }
                }
                .accessibilityIdentifier("timeline.list")
                .onChange(of: scrollToRow) { _, rowId in
                    guard let rowId else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(rowId, anchor: .top)
                    }
                    scrollToRow = nil
                }
            }
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
            StatusBanner(kind: .info, message: "Nothing leaving within 500 m in the next 90 min. Try another mode or move the map.")
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
