import Foundation
import os

/// One search box, three groups: stops and routes from the server, places
/// from MapKit. Typing is debounced 250 ms; the server and MapKit are
/// queried together and either may fail without hiding the other. A newer
/// query cancels the older one, and an older answer is never applied.
@MainActor
final class SearchModel: ObservableObject {
    struct Results: Equatable, Sendable {
        var stops: [StopSearchResult] = []
        var routes: [RouteSearchResult] = []
        var places: [PlaceResult] = []

        var isEmpty: Bool { stops.isEmpty && routes.isEmpty && places.isEmpty }

        static let none = Results()
    }

    static let debounce: Duration = .milliseconds(250)
    static let groupLimit = 8

    /// The text in the search field. Setting it schedules a search.
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var results = Results.none
    /// True from the first keystroke until results (or nothing) arrive.
    @Published private(set) var isSearching = false
    @Published private(set) var mode: TransportMode

    private let source: SearchSource
    private let places: PlaceSearching
    private let clock: AppClock
    private var task: Task<Void, Never>?
    private var generation = 0

    private nonisolated static let logger = Logger(subsystem: "com.turas", category: "SearchModel")

    init(source: SearchSource, places: PlaceSearching, clock: AppClock = .system, mode: TransportMode = .bus) {
        self.source = source
        self.places = places
        self.clock = clock
        self.mode = mode
    }

    /// The mode whose results come first. Re-runs the current query.
    func setMode(_ mode: TransportMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        queryChanged()
    }

    /// Back to the timeline: no text, no results, nothing pending.
    func clear() {
        query = ""
        if results != .none || isSearching {
            // The didSet only fires on a change; an already-empty query
            // still needs the pending work dropped.
            queryChanged()
        }
    }

    // MARK: - Searching

    private func queryChanged() {
        task?.cancel()
        task = nil
        generation += 1
        let generation = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = .none
            isSearching = false
            return
        }
        isSearching = true
        let (source, places, clock, mode) = (source, places, clock, mode)
        task = Task { [weak self] in
            guard (try? await clock.sleep(Self.debounce)) != nil else { return }
            async let server: SearchResponse? = {
                do {
                    return try await source.search(query: text, mode: mode)
                } catch {
                    if !ServerErrorText.isCancellation(error) {
                        Self.logger.warning("Search failed: \(error.localizedDescription)")
                    }
                    return nil
                }
            }()
            async let found: [PlaceResult] = {
                do {
                    return try await places.searchPlaces(text)
                } catch {
                    if !ServerErrorText.isCancellation(error) {
                        Self.logger.warning("Place search failed: \(error.localizedDescription)")
                    }
                    return []
                }
            }()
            let (response, placeResults) = await (server, found)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.results = Results(
                stops: Array((response?.stops ?? []).prefix(Self.groupLimit)),
                routes: Array((response?.routes ?? []).prefix(Self.groupLimit)),
                places: Array(placeResults.filter(Self.isInIreland).prefix(Self.groupLimit))
            )
            self.isSearching = false
        }
    }

    /// MapKit can answer with places far outside the region it was given;
    /// those would fly the map off the transit network.
    nonisolated static func isInIreland(_ place: PlaceResult) -> Bool {
        (51.3...55.5).contains(place.lat) && (-10.8...(-5.3)).contains(place.lon)
    }
}
