import CoreLocation
import SwiftUI

/// Search results in three groups: Stops, Routes, Places.
struct SearchResultsView: View {
    @ObservedObject var search: SearchModel
    /// Map centre, for telling same-name stops apart by distance.
    let mapCentre: CLLocationCoordinate2D
    let onSelectStop: (StopSearchResult) -> Void
    let onSelectRoute: (RouteSearchResult) -> Void
    let onSelectPlace: (PlaceResult) -> Void

    /// "Bus · 1.2 km": modes, then distance from the map centre, so
    /// same-name stops a few tens of metres apart can be told apart.
    nonisolated static func stopSubtitle(_ stop: StopSearchResult, from centre: CLLocationCoordinate2D) -> String {
        let parts = stop.modes.map(\.label) + [DepartureFormatting.distanceText(metres: metres(to: stop, from: centre))]
        return parts.joined(separator: " · ")
    }

    /// "Stop, College Green, Bus, 1.2 kilometres" for VoiceOver.
    nonisolated static func stopLabel(_ stop: StopSearchResult, from centre: CLLocationCoordinate2D) -> String {
        let parts = [AccessibilityText.stop(name: stop.name)] + stop.modes.map(\.label)
            + [AccessibilityText.distance(metres: metres(to: stop, from: centre))]
        return parts.joined(separator: ", ")
    }

    private nonisolated static func metres(to stop: StopSearchResult, from centre: CLLocationCoordinate2D) -> Int {
        Int(GeoUtils.straightLineDistance(lat1: centre.latitude, lon1: centre.longitude, lat2: stop.lat, lon2: stop.lon).rounded())
    }

    private var query: String { search.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                if query.isEmpty {
                    Text("Type a stop, a route number or a place.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 8)
                } else if search.results.isEmpty, !search.isSearching {
                    Text("No matches for “\(query)”.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 8)
                        .accessibilityIdentifier("search.empty")
                } else {
                    group("Stops", items: search.results.stops) { stop in
                        row(id: "search.stop.\(stop.id)", title: stop.name,
                            subtitle: Self.stopSubtitle(stop, from: mapCentre),
                            label: Self.stopLabel(stop, from: mapCentre)) { onSelectStop(stop) }
                    }
                    group("Routes", items: search.results.routes) { route in
                        Button {
                            onSelectRoute(route)
                        } label: {
                            HStack(spacing: 10) {
                                RouteBadge(route: route.name, mode: route.mode)
                                VStack(alignment: .leading, spacing: 2) {
                                    let headsigns = [route.headsign(for: 0), route.headsign(for: 1)].compactMap { $0 }.joined(separator: " ⇄ ")
                                    if !headsigns.isEmpty {
                                        Text(headsigns)
                                            .font(.body)
                                            .foregroundStyle(Theme.ink)
                                    }
                                    Text(route.operatorLabel)
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                            }
                            .padding(Theme.cardPadding)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(AccessibilityText.route(name: route.name, operatorName: route.operatorLabel))
                        .accessibilityHint("Shows this route on the map")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("search.route.\(route.id)")
                    }
                    group("Places", items: Array(search.results.places.enumerated()), id: \.offset) { indexed in
                        row(id: "search.place.\(indexed.offset)", title: indexed.element.name,
                            subtitle: indexed.element.subtitle ?? "", label: "Place, \(indexed.element.name)") { onSelectPlace(indexed.element) }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, Theme.gutter)
        }
        .accessibilityIdentifier("search.results")
    }

    @ViewBuilder
    private func group<Item: Identifiable, Row: View>(_ title: String, items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        group(title, items: items, id: \.id, row: row)
    }

    @ViewBuilder
    private func group<Item, ID: Hashable, Row: View>(_ title: String, items: [Item], id: KeyPath<Item, ID>, @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(items, id: id) { item in
                row(item)
            }
        }
    }

    private func row(id: String, title: String, subtitle: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.cardPadding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Moves the map there")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }
}
