import CoreLocation
import Foundation
import os
import SwiftUI

/// Everything leaving one stop, refreshed every 30 s while the stop view
/// is open and in the foreground. Route focus over the stop view pauses
/// it; closing focus resumes it with a fetch. A failed refresh keeps the
/// last rows; a 404 means the stop left the timetable and ends polling.
@MainActor
final class StopModel: ObservableObject {
    /// What the stop view shows besides its rows.
    enum Status: Equatable {
        /// Nothing fetched yet; the first request is pending or in flight.
        case loading
        /// Rows are current.
        case loaded
        /// The server answered with no departures.
        case empty
        /// The server is still loading its schedule (503); retried automatically.
        case starting
        /// The last refresh failed; `departures` is the last good answer, if any.
        case failed(message: String)
        /// The stop is no longer in the timetable (404); polling has stopped.
        case gone
    }

    static let refreshInterval: Duration = .seconds(30)
    static let emptyMessage = "Nothing leaving in the next 90 minutes"
    static let goneMessage = "This stop is no longer in the timetable"

    let target: StopTarget

    /// The stop as the server describes it (name, code), once it has answered.
    @Published private(set) var info: StopInfo?
    @Published private(set) var departures: [NearbyDeparture] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var status: Status = .loading

    private let source: StopSource
    private let clock: AppClock
    private let userLocation: CLLocationCoordinate2D?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    /// Between `start()` and `stop()`.
    private var isStarted = false
    /// `stop()` was called; a later `start()` does nothing (the stop view
    /// can close before the task that starts it runs).
    private var isStopped = false
    /// The scene is in the foreground.
    private var isForeground = true
    /// Route focus is open over the stop view.
    private var isPaused = false
    /// The server answered 404.
    private var isGone = false

    private static let logger = Logger(subsystem: "com.turas", category: "StopModel")

    init(target: StopTarget, userLocation: CLLocationCoordinate2D?, source: StopSource, clock: AppClock = .system) {
        self.target = target
        self.userLocation = userLocation
        self.source = source
        self.clock = clock
    }

    /// The server's name once known, else the pin's or result's.
    var name: String { info?.name ?? target.name }

    /// Straight-line metres from the user to the stop; nil without a location.
    var distanceFromUser: Int? {
        guard let userLocation else { return nil }
        let metres = GeoUtils.straightLineDistance(lat1: userLocation.latitude, lon1: userLocation.longitude, lat2: target.lat, lon2: target.lon)
        return Int(metres.rounded())
    }

    /// "Stop 7602 · 240 m", either part alone, or nil with neither.
    var caption: String? { Self.caption(code: info?.code, distanceMetres: distanceFromUser) }

    nonisolated static func caption(code: String?, distanceMetres: Int?) -> String? {
        var parts: [String] = []
        if let code, !code.isEmpty {
            parts.append("Stop \(code)")
        }
        if let distanceMetres {
            parts.append(DepartureFormatting.distanceText(metres: distanceMetres))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The stop to highlight when a row opens route focus.
    var focusStop: FocusStop {
        FocusStop(id: target.id, name: name, lat: target.lat, lon: target.lon)
    }

    // MARK: - Lifecycle

    /// Fetches once and returns, leaving the 30 s refresh running.
    func start() async {
        guard !isStopped else { return }
        isStarted = true
        await refresh()
        startRefreshing(immediately: false)
    }

    /// The stop view closed or switched stop: no more fetches, and an
    /// answer still in flight is dropped.
    func stop() {
        isStopped = true
        isStarted = false
        generation += 1
        cancelRefreshing()
    }

    /// Route focus opened over the stop view.
    func pause() {
        isPaused = true
        cancelRefreshing()
    }

    /// Route focus closed: fetch now and restart the loop.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        startRefreshing(immediately: true)
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            guard !isForeground else { return }
            isForeground = true
            // Back from the background: fetch now, not 30 s later.
            startRefreshing(immediately: true)
        case .background:
            isForeground = false
            cancelRefreshing()
        default:
            break
        }
    }

    /// The Retry button: fetch now and restart the loop.
    func retry() {
        startRefreshing(immediately: true)
    }

    // MARK: - Refreshing

    private func cancelRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Runs the loop: a refresh first when `immediately`, else a sleep
    /// first (the caller has just refreshed). Nothing runs while stopped,
    /// paused, in the background or gone.
    private func startRefreshing(immediately: Bool) {
        cancelRefreshing()
        guard isStarted, isForeground, !isPaused, !isGone else { return }
        let clock = clock
        let interval = Self.refreshInterval
        // Weak, and strong only for one refresh: a model nobody holds ends
        // the loop at its next tick instead of being kept alive by it.
        refreshTask = Task { [weak self] in
            if !immediately {
                guard (try? await clock.sleep(interval)) != nil else { return }
            }
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    await self.refresh()
                    if self.isGone { return }
                }
                guard (try? await clock.sleep(interval)) != nil else { return }
            }
        }
    }

    /// Fetches the stop's departures. A failure keeps the last rows and
    /// sets the status. A stopped model neither fetches nor applies an
    /// answer still in flight (the view it fed is gone).
    func refresh() async {
        guard !isStopped else { return }
        let generation = generation
        let (source, stopId) = (source, target.id)
        do {
            let response = try await source.fetchDepartures(stopId: stopId)
            guard generation == self.generation, !isStopped else { return }
            info = response.stop
            departures = response.departures
            lastUpdated = clock.now()
            status = response.departures.isEmpty ? .empty : .loaded
        } catch {
            guard generation == self.generation, !isStopped, !ServerErrorText.isCancellation(error) else { return }
            Self.logger.error("Stop fetch failed: \(error.localizedDescription)")
            switch error as? TurasServerError {
            case .httpError(statusCode: 404):
                // The stop left the timetable: stale rows would mislead.
                isGone = true
                departures = []
                status = .gone
            case .httpError(statusCode: 503):
                status = .starting
            case .httpError(statusCode: 429):
                break // The next tick retries; the user never sees a rate limit.
            default:
                status = .failed(message: ServerErrorText.message(for: error))
            }
        }
    }
}
