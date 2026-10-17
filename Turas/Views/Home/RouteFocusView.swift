import SwiftUI

/// The bottom panel in route focus: route, destination, stop and walk
/// time, the ⇄ button, then the next arrivals with live, late and
/// cancelled states.
struct RouteFocusView: View {
    @ObservedObject var focus: RouteFocusModel
    let onBack: () -> Void
    /// "Back to timeline", or "Back to stop" when focus came from the stop view.
    var backLabel = "Back to timeline"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.cardSpacing) {
            header
                .padding(.horizontal, Theme.gutter)
            ScrollView {
                LazyVStack(spacing: Theme.cardSpacing) {
                    arrivalsSection
                    if let lastUpdated = focus.lastUpdated {
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("focus.panel")
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
            .accessibilityLabel(backLabel)
            .accessibilityIdentifier("focus.back")

            RouteBadge(route: focus.route.name, mode: focus.mode)

            VStack(alignment: .leading, spacing: 2) {
                Text(focus.headsign.map { "To \($0)" } ?? "Direction \(focus.direction)")
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(stopLine)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button {
                Task { await focus.flipDirection() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Theme.card, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Flip direction")
            .accessibilityIdentifier("focus.flip")
        }
    }

    private var stopLine: String {
        guard let stop = focus.highlightedStop else { return "Finding a stop…" }
        if let minutes = focus.walkingMinutes {
            return "\(stop.name) · \(DepartureFormatting.walkText(minutes: minutes))"
        }
        if let metres = focus.distanceFromCentre {
            return "\(stop.name) · \(DepartureFormatting.distanceText(metres: metres))"
        }
        return stop.name
    }

    @ViewBuilder
    private var arrivalsSection: some View {
        if focus.isLoading || (focus.arrivals.isEmpty && focus.lastUpdated == nil && focus.errorMessage == nil) {
            StatusBanner(kind: .progress, message: "Loading times…")
        } else if focus.arrivals.isEmpty {
            StatusBanner(kind: focus.errorMessage == nil ? .info : .warning,
                         message: focus.errorMessage ?? "No upcoming times at this stop.")
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ForEach(Upcoming.arrivals(focus.arrivals, now: context.date).prefix(6)) { arrival in
                    arrivalRow(arrival, now: context.date)
                }
            }
            if let errorMessage = focus.errorMessage {
                StatusBanner(kind: .warning, message: "Couldn't refresh: \(errorMessage)")
            }
        }
    }

    private func arrivalRow(_ arrival: StopArrival, now: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: arrival.isCancelled ? "xmark.circle.fill" : arrival.isLive ? focus.mode.iconName : "clock")
                .font(.caption)
                .foregroundStyle(arrival.isCancelled ? Theme.cancelled : arrival.isLive ? Theme.brand : Theme.muted)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.headsign.map { "To \($0)" } ?? "To \(focus.headsign ?? "Direction \(focus.direction)")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .strikethrough(arrival.isCancelled)
                if arrival.isCancelled {
                    Text("Cancelled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.cancelled)
                } else if arrival.delay > 60 {
                    Text("+\(arrival.delay / 60) min late")
                        .font(.caption)
                        .foregroundStyle(Theme.late)
                }
            }
            Spacer()
            Text(ArrivalFormatting.minutesText(until: arrival.predictedArrival, now: now))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(arrival.isCancelled ? Theme.cancelled : arrival.isLive ? Theme.brand : Theme.muted)
                .strikethrough(arrival.isCancelled)
        }
        .padding(Theme.cardPadding)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.arrival(arrival, now: now))
        .accessibilityIdentifier("focus.arrival.\(arrival.id)")
    }
}
