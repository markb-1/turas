import Foundation
import os

/// Every Luas and train station, for the map pins: fetched from
/// `/stations` the first time a rail mode is selected and kept for the
/// session. A failed (or empty) answer is dropped, so the map falls back
/// to `/nearby`'s stops and the next selection of the mode asks again.
@MainActor
final class StationStore: ObservableObject {
    @Published private(set) var stations: [TransportMode: [Station]] = [:]

    private let source: StationSource
    private var tasks: [TransportMode: Task<Void, Never>] = [:]

    private static let logger = Logger(subsystem: "com.turas", category: "StationStore")

    init(source: StationSource) {
        self.source = source
    }

    /// The mode's stations, or nil until they are loaded.
    func stations(for mode: TransportMode) -> [Station]? {
        stations[mode]
    }

    /// A fetch for the mode is in flight.
    func isLoading(_ mode: TransportMode) -> Bool {
        tasks[mode] != nil
    }

    /// Fetches the mode's stations unless they are loaded or loading. Bus
    /// has ~10,000 stops and is never fetched: its pins come from `/nearby`.
    func load(_ mode: TransportMode) {
        guard mode != .bus, stations[mode] == nil, tasks[mode] == nil else { return }
        let source = source
        tasks[mode] = Task { [weak self] in
            do {
                let list = try await source.fetchStations(mode: mode)
                if list.isEmpty {
                    Self.logger.error("No \(mode.rawValue) stations listed; using nearby stops")
                } else {
                    self?.stations[mode] = list
                }
            } catch {
                if !ServerErrorText.isCancellation(error) {
                    Self.logger.error("Station fetch failed for \(mode.rawValue): \(error.localizedDescription)")
                }
            }
            self?.tasks[mode] = nil
        }
    }
}
