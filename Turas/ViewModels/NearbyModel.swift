import CoreLocation
import Foundation
import os
import SwiftUI

/// Fetches what is leaving near the map centre for one mode, and keeps the
/// last good answer so the timeline never goes blank on a failed refresh.
///
/// The camera reports where it settled; about 0.6 s later (if it moved more
/// than 50 m from the last fetch) the rows are fetched, then refreshed
/// every 30 s while the app is active. A (centre, mode) change bumps
/// `generation`, and a response for an older generation is dropped.
@MainActor
final class NearbyModel: ObservableObject {
    /// What the timeline shows besides its rows.
    enum Status: Equatable {
        /// Nothing fetched yet for this mode; a request is pending or in flight.
        case loading
        /// Rows are current.
        case loaded
        /// The server answered with no departures.
        case empty
        /// The server is still loading its schedule (503); retried automatically.
        case starting
        /// The last refresh failed; `result` is the last good answer, if any.
        case failed(message: String)
    }

    static let settleDelay: Duration = .milliseconds(600)
    static let settleDistance: Double = 50
    static let refreshInterval: Duration = .seconds(30)

    @Published private(set) var result: NearbyResponse?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var status: Status = .loading
    @Published private(set) var mode: TransportMode

    private let source: NearbySource
    private let clock: AppClock
    /// The centre the current rows (or the in-flight request) are for.
    private(set) var fetchedCentre: CLLocationCoordinate2D?
    private var settleTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var isActive = true

    private static let logger = Logger(subsystem: "com.turas", category: "NearbyModel")

    init(source: NearbySource, clock: AppClock = .system, mode: TransportMode = .bus) {
        self.source = source
        self.clock = clock
        self.mode = mode
    }

    var departures: [NearbyDeparture] { result?.departures ?? [] }
    var stops: [DepartureStop] { result?.stops ?? [] }
    /// Whether the settle timer is running (a fetch will follow).
    var hasPendingFetch: Bool { settleTask != nil }

    /// The first row at a stop; tapping a pin scrolls to it.
    func firstRow(atStop stopId: String) -> NearbyDeparture? {
        departures.first { $0.stopId == stopId }
    }

    // MARK: - Camera

    /// The map camera stopped at `centre`. Fetches 0.6 s later unless the
    /// centre is within 50 m of the last fetch. A newer settle replaces a
    /// pending one, so panning across town fetches only where it ends.
    func cameraSettled(at centre: CLLocationCoordinate2D) {
        settleTask?.cancel()
        settleTask = nil
        guard isActive else { return }
        if let fetchedCentre, Self.distance(fetchedCentre, centre) < Self.settleDistance {
            return
        }
        let clock = clock
        settleTask = Task { [weak self] in
            guard (try? await clock.sleep(Self.settleDelay)) != nil, let self, !Task.isCancelled else { return }
            self.settleTask = nil
            self.beginFetching(centre: centre)
        }
    }

    // MARK: - Mode, retry, lifecycle

    /// Switches mode: the old mode's rows go and the new mode is fetched now.
    func setMode(_ mode: TransportMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        result = nil
        lastUpdated = nil
        status = .loading
        if let fetchedCentre {
            beginFetching(centre: fetchedCentre)
        }
    }

    /// Fetches again now (the Retry button).
    func retry() {
        guard let fetchedCentre else { return }
        beginFetching(centre: fetchedCentre)
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            resume()
        case .background:
            pause()
        default:
            break
        }
    }

    /// Stops the timer and the refresh loop (the app left the foreground,
    /// or route focus is showing).
    func pause() {
        isActive = false
        settleTask?.cancel()
        settleTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Fetches now and restarts the 30 s refresh. The old rows and their
    /// timestamp stay until the fetch lands.
    func resume() {
        guard !isActive else { return }
        isActive = true
        if let fetchedCentre {
            beginFetching(centre: fetchedCentre)
        }
    }

    // MARK: - Fetching

    private func beginFetching(centre: CLLocationCoordinate2D) {
        fetchedCentre = centre
        generation += 1
        let generation = generation
        refreshTask?.cancel()
        refreshTask = nil
        guard isActive else { return }
        let clock = clock
        // Weak, and strong only for one fetch: a model nobody holds ends the
        // loop at its next tick instead of being kept alive by it.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    await self.fetch(centre: centre, generation: generation)
                }
                guard (try? await clock.sleep(Self.refreshInterval)) != nil else { return }
            }
        }
    }

    private func fetch(centre: CLLocationCoordinate2D, generation: Int) async {
        let mode = mode
        do {
            let response = try await source.fetchNearby(lat: centre.latitude, lon: centre.longitude, mode: mode)
            guard generation == self.generation else { return }
            result = response
            lastUpdated = clock.now()
            status = response.departures.isEmpty ? .empty : .loaded
        } catch {
            guard generation == self.generation, !ServerErrorText.isCancellation(error) else { return }
            Self.logger.error("Nearby fetch failed: \(error.localizedDescription)")
            switch error as? TurasServerError {
            case .httpError(statusCode: 503):
                status = .starting
            case .httpError(statusCode: 429):
                break // The next tick retries; the user never sees a rate limit.
            default:
                status = .failed(message: ServerErrorText.message(for: error))
            }
        }
    }

    nonisolated static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoUtils.straightLineDistance(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
    }
}
