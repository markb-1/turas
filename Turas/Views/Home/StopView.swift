import SwiftUI

/// The bottom panel for one stop: back, the stop's name and "Stop 7602 ·
/// 240 m", then one row per route and direction leaving it, soonest
/// first, with the same live, late and cancelled states as the timeline.
struct StopView: View {
    @ObservedObject var stop: StopModel
    let onBack: () -> Void
    let onSelect: (NearbyDeparture) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.cardSpacing) {
            header
                .padding(.horizontal, Theme.gutter)
            banner
                .padding(.horizontal, Theme.gutter)
            ScrollView {
                LazyVStack(spacing: Theme.cardSpacing) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ForEach(stop.departures) { departure in
                            Button {
                                onSelect(departure)
                            } label: {
                                DepartureCard(departure: departure, stopName: nil, mode: stop.target.mode,
                                              now: context.date, identifierPrefix: "stop.row")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("stop.row.\(departure.id)")
                        }
                    }
                    if let lastUpdated = stop.lastUpdated {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(ArrivalFormatting.updatedText(since: lastUpdated, now: context.date))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.gutter)
            }
            .accessibilityIdentifier("stop.list")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.panel")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to timeline")
            .accessibilityIdentifier("stop.back")

            Image(systemName: stop.target.mode.iconName)
                .font(.body)
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("stop.name")
                if let caption = stop.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("stop.caption")
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch stop.status {
        case .loading:
            StatusBanner(kind: .progress, message: "Finding what's leaving…")
        case .loaded:
            EmptyView()
        case .starting:
            StatusBanner(kind: .progress, message: "Turas is starting up…")
        case .empty:
            StatusBanner(kind: .info, message: StopModel.emptyMessage)
        case .gone:
            StatusBanner(kind: .info, message: StopModel.goneMessage)
        case .failed(let message):
            if let lastUpdated = stop.lastUpdated {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    StatusBanner(kind: .warning, message: ArrivalFormatting.updatedText(since: lastUpdated, now: context.date),
                                 actionTitle: "Retry", action: stop.retry)
                }
            } else {
                StatusBanner(kind: .warning, message: message, actionTitle: "Retry", action: stop.retry)
            }
        }
    }
}
