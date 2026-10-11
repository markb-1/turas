import CoreLocation
import SwiftUI
import XCTest
@testable import Turas

@MainActor
final class NearbyModelTests: XCTestCase {
    private let clock = ManualClock()
    private let collegeGreen = CLLocationCoordinate2D(latitude: 53.3441, longitude: -6.2595)

    private func makeModel(source: FakeNearbySource) -> NearbyModel {
        NearbyModel(source: source, clock: clock.appClock)
    }

    /// Settles the camera and waits for the model's 0.6 s timer to start.
    private func settle(_ model: NearbyModel, at centre: CLLocationCoordinate2D, expectingSleepers: Int) async {
        model.cameraSettled(at: centre)
        await waitUntil("settle timer") { self.clock.sleeperCount == expectingSleepers }
    }

    /// Settles at `centre`, fires the timer and waits for the first fetch to land.
    private func loadFirst(_ model: NearbyModel, source: FakeNearbySource, at centre: CLLocationCoordinate2D) async {
        await settle(model, at: centre, expectingSleepers: 1)
        clock.advance(by: 0.6)
        await waitUntil("first load") { model.result != nil || model.status != .loading }
        await waitUntil("refresh loop sleeping") { self.clock.sleeperCount == 1 }
    }

    private func moved(_ metresNorth: Double, from origin: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + metresNorth / 111_195, longitude: origin.longitude)
    }

    // MARK: - Settling

    func testRapidPanningFetchesOnlyTheFinalCentre() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)

        var last = collegeGreen
        for step in 1...10 {
            last = moved(Double(step) * 200, from: collegeGreen)
            model.cameraSettled(at: last)
        }
        XCTAssertTrue(model.hasPendingFetch)
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 0.6)
        await waitUntil("fetch") { model.status == .loaded }

        let calls = await source.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first, NearbyCall(lat: last.latitude, lon: last.longitude, mode: .bus))
        XCTAssertEqual(model.result, SampleData.nearby())
        XCTAssertEqual(model.lastUpdated, clock.now)
        XCTAssertEqual(model.departures.map(\.route), ["39A", "16"])
        XCTAssertEqual(model.stops.map(\.name), ["College Green", "Dame Street"])
    }

    func testFetchWaitsForTheSettleDelay() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await settle(model, at: collegeGreen, expectingSleepers: 1)

        clock.advance(by: 0.5)
        let early = await source.calls.count
        XCTAssertEqual(early, 0, "nothing before 0.6 s")
        clock.advance(by: 0.1)
        await waitUntil { model.status == .loaded }
    }

    func testSmallMoveDoesNotRefetchButLargerOneDoes() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)

        model.cameraSettled(at: moved(30, from: collegeGreen))
        XCTAssertFalse(model.hasPendingFetch, "under 50 m is the same place")

        let farther = moved(60, from: collegeGreen)
        model.cameraSettled(at: farther)
        XCTAssertTrue(model.hasPendingFetch)
        await waitUntil { self.clock.sleeperCount == 2 }
        clock.advance(by: 0.6)
        await waitUntil { source.callCount == 2 }
        let calls = await source.calls
        XCTAssertEqual(calls.last?.lat ?? 0, farther.latitude, accuracy: 1e-9)
    }

    // MARK: - Refreshing

    func testRefreshesEvery30Seconds() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)

        clock.advance(by: 29)
        let before = await source.calls.count
        XCTAssertEqual(before, 1)
        clock.advance(by: 1)
        await waitUntil { source.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 30)
        await waitUntil { source.callCount == 3 }
    }

    func testResumeAfterHoursFetchesImmediatelyAndKeepsStaleRows() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)
        let firstUpdate = model.lastUpdated

        model.scenePhaseChanged(to: .background)
        await waitUntil("refresh loop cancelled") { self.clock.sleeperCount == 0 }
        clock.advance(by: 3 * 3600)
        let whilePaused = await source.calls.count
        XCTAssertEqual(whilePaused, 1, "no fetches in the background")
        XCTAssertEqual(model.result, SampleData.nearby(), "stale rows stay")
        XCTAssertEqual(model.lastUpdated, firstUpdate)

        model.scenePhaseChanged(to: .active)
        await waitUntil { source.callCount == 2 }
        await waitUntil { model.lastUpdated == self.clock.now }
    }

    func testBackgroundCancelsAPendingSettle() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await settle(model, at: collegeGreen, expectingSleepers: 1)
        model.pause()
        await waitUntil { self.clock.sleeperCount == 0 }
        XCTAssertFalse(model.hasPendingFetch)
        clock.advance(by: 1)
        let calls = await source.calls.count
        XCTAssertEqual(calls, 0)
        // Resuming with no fetched centre fetches nothing until the camera settles.
        model.resume()
        XCTAssertFalse(model.hasPendingFetch)
    }

    func testReleasedModelStopsRefreshing() async {
        let source = FakeNearbySource()
        var model: NearbyModel? = makeModel(source: source)
        weak let released = model
        await loadFirst(model!, source: source, at: collegeGreen)

        model = nil
        XCTAssertNil(released, "the refresh loop must not keep the model alive")
        clock.advance(by: 30)
        await waitUntil("loop exits") { self.clock.sleeperCount == 0 }
        XCTAssertEqual(source.callCount, 1, "no fetch after the model is gone")
    }

    // MARK: - Errors

    func testOfflineAtLaunchShowsRetryAndRetryRecovers() async {
        let source = FakeNearbySource()
        await source.setError(URLError(.notConnectedToInternet))
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)

        XCTAssertEqual(model.status, .failed(message: "No internet connection. Check your network."))
        XCTAssertNil(model.result)
        XCTAssertNil(model.lastUpdated)

        await source.setError(nil)
        model.retry()
        await waitUntil { model.status == .loaded }
        let calls = await source.calls.count
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.result, SampleData.nearby())
    }

    func testFailedRefreshKeepsLastRows() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)
        let firstUpdate = model.lastUpdated

        await source.setError(TurasServerError.httpError(statusCode: 500))
        clock.advance(by: 30)
        await waitUntil { model.status == .failed(message: "Service temporarily unavailable. Retrying...") }
        XCTAssertEqual(model.result, SampleData.nearby())
        XCTAssertEqual(model.lastUpdated, firstUpdate, "the timestamp is of the last good answer")
    }

    func testLuas502KeepsLastRowsAndRetries() async {
        // The server answers 502 when every Luas forecast call fails.
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)
        model.setMode(.luas)
        await waitUntil { model.departures.map(\.route) == ["Red"] }
        await waitUntil { self.clock.sleeperCount == 1 }

        await source.setError(TurasServerError.httpError(statusCode: 502))
        clock.advance(by: 30)
        await waitUntil { model.status == .failed(message: "Service temporarily unavailable. Retrying...") }
        XCTAssertEqual(model.departures.map(\.route), ["Red"], "stale Luas rows stay with the banner")

        await source.setError(nil)
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 30)
        await waitUntil { model.status == .loaded }
    }

    func test503ShowsStartingAndRetriesOnTheNextTick() async {
        let source = FakeNearbySource()
        await source.setError(TurasServerError.httpError(statusCode: 503))
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)
        XCTAssertEqual(model.status, .starting)

        await source.setError(nil)
        clock.advance(by: 30)
        await waitUntil { model.status == .loaded }
    }

    func test429IsSilent() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)

        await source.setError(TurasServerError.httpError(statusCode: 429))
        clock.advance(by: 30)
        await waitUntil { source.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(model.status, .loaded, "rate limiting never shows a message")
        XCTAssertEqual(model.result, SampleData.nearby())
    }

    func testEmptyResponseIsEmptyStatus() async {
        let source = FakeNearbySource()
        await source.setResponse(.empty, for: .bus)
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)
        XCTAssertEqual(model.status, .empty)
        XCTAssertEqual(model.result, .empty)
    }

    // MARK: - Mode and staleness

    func testModeSwitchClearsRowsAndFetchesNow() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)

        model.setMode(.luas)
        XCTAssertNil(model.result)
        XCTAssertEqual(model.status, .loading)
        XCTAssertEqual(model.mode, .luas)
        await waitUntil { model.status == .loaded }
        let calls = await source.calls
        XCTAssertEqual(calls.last?.mode, .luas)
        XCTAssertEqual(model.departures.map(\.route), ["Red"])

        model.setMode(.luas)
        let after = await source.calls.count
        XCTAssertEqual(after, 2, "selecting the current mode is a no-op")
    }

    func testStaleResponseIsDropped() async {
        // The bus answer is held 2 s and the luas one 1 s, so the older bus
        // answer arrives after the luas one and must be dropped.
        let fake = FakeNearbySource(clock: clock)
        let source = AnswerCountingSource(fake)
        await fake.setDelay(.seconds(2))
        let model = NearbyModel(source: source, clock: clock.appClock)
        await settle(model, at: collegeGreen, expectingSleepers: 1)
        clock.advance(by: 0.6)
        await waitUntil("bus fetch in flight") { self.clock.sleeperCount == 1 }

        await fake.setDelay(.seconds(1))
        model.setMode(.luas)
        await waitUntil("luas fetch in flight") { self.clock.sleeperCount == 2 }
        clock.advance(by: 1)
        await waitUntil { model.status == .loaded }
        XCTAssertEqual(model.departures.map(\.route), ["Red"])
        await waitUntil("bus answer held, luas refresh sleeping") { self.clock.sleeperCount == 2 }

        clock.advance(by: 1)
        await waitUntil("stale bus answer arrived") { source.answers == 2 }
        XCTAssertEqual(model.departures.map(\.route), ["Red"], "the older bus answer never overwrites the luas one")
        XCTAssertEqual(model.status, .loaded)
        XCTAssertEqual(model.mode, .luas)
        let modes = await fake.calls.map(\.mode)
        XCTAssertEqual(modes, [.bus, .luas])
    }

    func testStaleErrorIsDropped() async {
        let fake = FakeNearbySource(clock: clock)
        let source = AnswerCountingSource(fake)
        await fake.setDelay(.seconds(2))
        let model = NearbyModel(source: source, clock: clock.appClock)
        await settle(model, at: collegeGreen, expectingSleepers: 1)
        clock.advance(by: 0.6)
        await waitUntil("bus fetch in flight") { self.clock.sleeperCount == 1 }

        await fake.setDelay(.seconds(1))
        model.setMode(.luas)
        await waitUntil("luas fetch in flight") { self.clock.sleeperCount == 2 }
        clock.advance(by: 1)
        await waitUntil { model.status == .loaded }
        await waitUntil("bus answer held, luas refresh sleeping") { self.clock.sleeperCount == 2 }

        // The held bus request now fails; its error belongs to a superseded request.
        await fake.setError(TurasServerError.httpError(statusCode: 500))
        clock.advance(by: 1)
        await waitUntil("stale bus error arrived") { source.answers == 2 }
        XCTAssertEqual(model.status, .loaded, "a superseded request's error never shows")
        XCTAssertEqual(model.departures.map(\.route), ["Red"])
    }

    func testFirstRowAtStop() async {
        let source = FakeNearbySource()
        let model = makeModel(source: source)
        await loadFirst(model, source: source, at: collegeGreen)
        XCTAssertEqual(model.firstRow(atStop: SampleData.dameStreet.id)?.route, "16")
        XCTAssertNil(model.firstRow(atStop: "nope"))
    }

    func testDistance() {
        XCTAssertEqual(NearbyModel.distance(collegeGreen, moved(50, from: collegeGreen)), 50, accuracy: 0.5)
    }
}

/// Passes calls through and counts answers on the main actor, in the same
/// job that hands the answer back to the model, so a test that sees the
/// count has also seen what the model did with the answer.
@MainActor
private final class AnswerCountingSource: NearbySource {
    private let inner: NearbySource
    private(set) var answers = 0

    init(_ inner: NearbySource) {
        self.inner = inner
    }

    func fetchNearby(lat: Double, lon: Double, mode: TransportMode) async throws -> NearbyResponse {
        defer { answers += 1 }
        return try await inner.fetchNearby(lat: lat, lon: lon, mode: mode)
    }
}
