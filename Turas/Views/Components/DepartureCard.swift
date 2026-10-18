import SwiftUI

/// One departures row: badge, destination, stop and distance, and the
/// times. In the stop view the stop line is dropped (the header names the
/// stop). At accessibility type sizes the times move under the text so
/// nothing truncates.
struct DepartureCard: View {
    let departure: NearbyDeparture
    /// The stop under the destination; nil in the stop view.
    let stopName: String?
    let mode: TransportMode
    let now: Date
    /// The panel the card is in, for UI tests: "timeline.row" or "stop.row".
    var identifierPrefix = "timeline.row"

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    TimeStack(times: departure.times, now: now)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    header
                    Spacer(minLength: 8)
                    TimeStack(times: departure.times, now: now)
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.departure(departure, stopName: stopName, now: now))
        .accessibilityHint("Shows this route on the map with its next times")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("\(identifierPrefix).\(departure.id)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RouteBadge(route: departure.route, mode: mode)
            VStack(alignment: .leading, spacing: 2) {
                Text(departure.destination)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                if let stopName {
                    Text("\(stopName) · \(DepartureFormatting.distanceText(metres: departure.distanceM))")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}
