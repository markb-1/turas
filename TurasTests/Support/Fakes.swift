import Foundation
@testable import Turas

/// Canned data shared by the model tests.
enum SampleData {
    static let elevenUTC = Date(timeIntervalSince1970: 1_791_630_000) // 2026-10-10T11:00:00Z

    static let collegeGreen = DepartureStop(id: "8220DB000400", name: "College Green", lat: 53.3441, lon: -6.2595, distanceM: 90)
    static let dameStreet = DepartureStop(id: "8220DB000401", name: "Dame Street", lat: 53.3439, lon: -6.2660, distanceM: 420)

    static func time(_ minutes: Int, source: DepartureSource = .live, cancelled: Bool = false) -> DepartureTime {
        DepartureTime(tripId: "trip-\(minutes)", at: elevenUTC.addingTimeInterval(TimeInterval(minutes * 60)),
                      delay: 0, source: source, cancelled: cancelled)
    }

    /// Two bus rows at two stops, or one Luas/train row, all timed from `elevenUTC`.
    static func nearby(mode: TransportMode = .bus) -> NearbyResponse {
        switch mode {
        case .bus:
            return NearbyResponse(stops: [collegeGreen, dameStreet], departures: [
                NearbyDeparture(route: "39A", agencyId: "1", direction: 0, headsign: "Ongar", stopId: collegeGreen.id,
                                distanceM: 90, times: [time(2), time(14, source: .realtime), time(27, source: .timetable)]),
                NearbyDeparture(route: "16", agencyId: "1", direction: 1, headsign: "Ballinteer", stopId: dameStreet.id,
                                distanceM: 420, times: [time(5)]),
            ])
        case .luas:
            let abbey = DepartureStop(id: "LUAS-ABB", name: "Abbey Street", lat: 53.3485, lon: -6.2583, distanceM: 300)
            return NearbyResponse(stops: [abbey], departures: [
                NearbyDeparture(route: "Red", agencyId: "10000", direction: 0, headsign: "Tallaght", stopId: abbey.id,
                                distanceM: 300, times: [time(3), time(9)]),
            ])
        case .train:
            let tara = DepartureStop(id: "IR-TARA", name: "Tara Street", lat: 53.3470, lon: -6.2545, distanceM: 350)
            return NearbyResponse(stops: [tara], departures: [
                NearbyDeparture(route: "DART", agencyId: "IR", direction: 1, headsign: "Bray", stopId: tara.id,
                                distanceM: 350, times: [time(6)]),
            ])
        }
    }
}

struct NearbyCall: Equatable {
    let lat: Double
    let lon: Double
    let mode: TransportMode
}

/// A scripted NearbySource. With a clock and a delay it sleeps on the test
/// clock before answering, so tests can interleave responses. The sleep is
/// detached, so cancelling the caller does not cut the answer short: tests
/// of the models' generation guards need the late answer to arrive.
actor FakeNearbySource: NearbySource {
    static func wait(_ delay: Duration, on clock: ManualClock) async {
        await Task.detached { try? await clock.sleep(for: delay) }.value
    }

    private let clock: ManualClock?
    private var responses: [TransportMode: NearbyResponse] = [.bus: SampleData.nearby(mode: .bus), .luas: SampleData.nearby(mode: .luas), .train: SampleData.nearby(mode: .train)]
    private var error: Error?
    private var delay: Duration?
    private(set) var calls: [NearbyCall] = [] {
        didSet { callCountBox.value = calls.count }
    }
    /// `calls.count`, readable without awaiting (for `waitUntil` closures).
    nonisolated var callCount: Int { callCountBox.value }
    private nonisolated let callCountBox = AtomicInt()

    init(clock: ManualClock? = nil) {
        self.clock = clock
    }

    func setResponse(_ response: NearbyResponse, for mode: TransportMode) { responses[mode] = response }
    func setError(_ error: Error?) { self.error = error }
    func setDelay(_ delay: Duration?) { self.delay = delay }

    func fetchNearby(lat: Double, lon: Double, mode: TransportMode) async throws -> NearbyResponse {
        calls.append(NearbyCall(lat: lat, lon: lon, mode: mode))
        if let delay, let clock {
            await Self.wait(delay, on: clock)
        }
        if let error { throw error }
        return responses[mode] ?? .empty
    }
}

/// A scripted SearchSource. Each call answers with the response, error and
/// delay scripted when it was made, so with a clock and a delay a test can
/// hold one answer, script and deliver a newer one, then release the held
/// (stale) answer by advancing the clock; `answerCount` shows when it lands.
actor FakeSearchSource: SearchSource {
    struct Query: Equatable {
        let query: String
        let mode: TransportMode?
    }

    private let clock: ManualClock?
    private var response = SearchResponse.empty
    private var error: Error?
    private var delay: Duration?
    private(set) var queries: [Query] = [] {
        didSet { queryCountBox.value = queries.count }
    }
    /// `queries.count`, readable without awaiting.
    nonisolated var queryCount: Int { queryCountBox.value }
    private nonisolated let queryCountBox = AtomicInt()
    /// Calls that have returned or thrown, readable without awaiting.
    nonisolated var answerCount: Int { answerCountBox.value }
    private nonisolated let answerCountBox = AtomicInt()

    init(clock: ManualClock? = nil) {
        self.clock = clock
    }

    func setResponse(_ response: SearchResponse) { self.response = response }
    func setError(_ error: Error?) { self.error = error }
    func setDelay(_ delay: Duration?) { self.delay = delay }

    func search(query: String, mode: TransportMode?) async throws -> SearchResponse {
        queries.append(Query(query: query, mode: mode))
        // Snapshot before suspending: a later setResponse must not change an
        // answer already in flight.
        let (response, error, delay) = (self.response, self.error, self.delay)
        if let delay, let clock {
            await FakeNearbySource.wait(delay, on: clock)
        }
        answerCountBox.value += 1
        if let error { throw error }
        return response
    }
}

/// A scripted FocusSource that counts calls.
actor FakeFocusSource: FocusSource {
    private var vehicles: [Vehicle] = []
    private var arrivals: [StopArrival] = []
    private var luasArrivals: [StopArrival] = []
    private var error: Error?
    private(set) var vehicleFetches = 0
    private(set) var arrivalFetches = 0 {
        didSet { arrivalFetchBox.value = arrivalFetches }
    }
    private(set) var luasFetches = 0 {
        didSet { luasFetchBox.value = luasFetches }
    }
    /// Counts readable without awaiting.
    nonisolated var arrivalFetchCount: Int { arrivalFetchBox.value }
    nonisolated var luasFetchCount: Int { luasFetchBox.value }
    private nonisolated let arrivalFetchBox = AtomicInt()
    private nonisolated let luasFetchBox = AtomicInt()
    private(set) var lastArrivalRequest: (stopId: String, route: RouteRef, direction: Int)?

    func setVehicles(_ vehicles: [Vehicle]) { self.vehicles = vehicles }
    func setArrivals(_ arrivals: [StopArrival]) { self.arrivals = arrivals }
    func setLuasArrivals(_ arrivals: [StopArrival]) { self.luasArrivals = arrivals }
    func setError(_ error: Error?) { self.error = error }

    func fetchVehicles(mode: TransportMode) async throws -> [Vehicle] {
        vehicleFetches += 1
        if let error { throw error }
        return vehicles.filter { $0.mode == mode }
    }

    func fetchArrivals(stopId: String, route: RouteRef, direction: Int) async throws -> [StopArrival] {
        arrivalFetches += 1
        lastArrivalRequest = (stopId, route, direction)
        if let error { throw error }
        return arrivals
    }

    func fetchLuasArrivals(stopId: String, direction: Int, routeName: String) async throws -> [StopArrival] {
        luasFetches += 1
        lastArrivalRequest = (stopId, RouteRef(name: routeName), direction)
        if let error { throw error }
        return luasArrivals
    }
}

/// A lock-protected counter the fakes expose for synchronous reads, so a
/// `waitUntil` closure can watch a call count without awaiting the actor.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
