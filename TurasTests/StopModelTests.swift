import CoreLocation
import SwiftUI
import XCTest
@testable import Turas

@MainActor
final class StopModelTests: XCTestCase {
    private let clock = ManualClock()
    private let collegeGreen = StopTarget(SampleData.collegeGreen, mode: .bus)

    private func makeModel(source: FakeStopSource, target: StopTarget? = nil, userLocation: CLLocationCoordinate2D? = nil) -> StopModel {
        StopModel(target: target ?? collegeGreen, userLocation: userLocation, source: source, clock: clock.appClock)
    }

    /// Starts the model and waits for its refresh loop to go to sleep.
    private func startAndSettle(_ model: StopModel) async {
        await model.start()
        await waitUntil("refresh loop sleeping") { self.clock.sleeperCount == 1 }
    }

    /// Lets any wrongly running loop take its turn (no clock time passes).
    private func drain(_ source: FakeStopSource) async {
        for _ in 0..<50 {
            await Task.yield()
            _ = await source.stopIds
        }
    }

    // MARK: - Loading and refreshing

    func testStartFetchesThenRefreshesEvery30Seconds() async {
        let source = FakeStopSource()
        let model = makeModel(source: source)
        XCTAssertEqual(model.status, .loading)
        XCTAssertEqual(model.name, "College Green", "the target's name until the server answers")
        XCTAssertNil(model.caption, "no code known yet, no user location")

        await startAndSettle(model)
        XCTAssertEqual(model.status, .loaded)
        XCTAssertEqual(model.departures.map(\.route), ["39A", "46A"])
        XCTAssertEqual(model.info?.code, "400")
        XCTAssertEqual(model.caption, "Stop 400")
        XCTAssertEqual(model.lastUpdated, clock.now)
        let stopIds = await source.stopIds
        XCTAssertEqual(stopIds, [collegeGreen.id])

        clock.advance(by: 29)
        await drain(source)
        XCTAssertEqual(source.callCount, 1, "nothing before 30 s")
        clock.advance(by: 1)
        await waitUntil { source.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: 30)
        await waitUntil { source.callCount == 3 }

        model.stop()
        await waitUntil("loop ends on stop") { self.clock.sleeperCount == 0 }
        clock.advance(by: 60)
        await drain(source)
        XCTAssertEqual(source.callCount, 3, "a stopped model never fetches again")
    }

    func testEmptyAnswerIsEmptyStatus() async {
        let source = FakeStopSource()
        let info = StopInfo(id: collegeGreen.id, name: "College Green", code: "400", lat: collegeGreen.lat, lon: collegeGreen.lon, modes: [.bus])
        await source.setResponse(StopDepartures(stop: info, departures: []), for: collegeGreen.id)
        let model = makeModel(source: source)
        await startAndSettle(model)
        XCTAssertEqual(model.status, .empty)
        XCTAssertEqual(model.departures, [])
        XCTAssertEqual(model.lastUpdated, clock.now)
        XCTAssertEqual(StopModel.emptyMessage, "Nothing leaving in the next 90 minutes")
        model.stop()
    }

    func testServerNameReplacesThePinsName() async {
        let source = FakeStopSource()
        let model = makeModel(source: source, target: StopTarget(id: collegeGreen.id, name: "College Grn", lat: collegeGreen.lat, lon: collegeGreen.lon, mode: .bus))
        await startAndSettle(model)
        XCTAssertEqual(model.name, "College Green")
        XCTAssertEqual(model.focusStop, FocusStop(id: collegeGreen.id, name: "College Green", lat: collegeGreen.lat, lon: collegeGreen.lon))
        model.stop()
    }

    // MARK: - Errors

    func testFailedRefreshKeepsLastRowsAndRetryFetchesNow() async {
        let source = FakeStopSource()
        let model = makeModel(source: source)
        await startAndSettle(model)
        let firstUpdate = model.lastUpdated

        await source.setError(TurasServerError.httpError(statusCode: 500))
        clock.advance(by: 30)
        await waitUntil { model.status == .failed(message: "Service temporarily unavailable. Retrying...") }
        XCTAssertEqual(model.departures.map(\.route), ["39A", "46A"], "the last good rows stay")
        XCTAssertEqual(model.lastUpdated, firstUpdate, "the timestamp is of the last good answer")
        await waitUntil { self.clock.sleeperCount == 1 }

        await source.setError(nil)
        model.retry()
        await waitUntil { model.status == .loaded }
        XCTAssertEqual(source.callCount, 3, "retry fetched at once")
        XCTAssertEqual(model.lastUpdated, clock.now)
        model.stop()
    }

    func testOfflineAtStartShowsTheMessageWithNoRows() async {
        let source = FakeStopSource()
        await source.setError(URLError(.notConnectedToInternet))
        let model = makeModel(source: source)
        await startAndSettle(model)
        XCTAssertEqual(model.status, .failed(message: "No internet connection. Check your network."))
        XCTAssertEqual(model.departures, [])
        XCTAssertNil(model.lastUpdated)
        XCTAssertNil(model.info)
        model.stop()
    }

    func test404IsGoneClearsRowsAndEndsPolling() async {
        let source = FakeStopSource()
        let model = makeModel(source: source)
        await startAndSettle(model)

        await source.setResponse(nil, for: collegeGreen.id) // the fake answers 404 for an unknown stop
        clock.advance(by: 30)
        await waitUntil { model.status == .gone }
        XCTAssertEqual(model.departures, [], "a stop that left the timetable has nothing leaving")
        XCTAssertEqual(StopModel.goneMessage, "This stop is no longer in the timetable")
        await waitUntil("polling ends") { self.clock.sleeperCount == 0 }
        clock.advance(by: 60)
        await drain(source)
        XCTAssertEqual(source.callCount, 2)

        model.retry()
        await drain(source)
        XCTAssertEqual(source.callCount, 2, "nothing to retry")

        await source.setResponse(SampleData.stopDepartures(for: collegeGreen.id), for: collegeGreen.id)
        await model.refresh()
        XCTAssertEqual(source.callCount, 2, "a gone stop is not fetched")
        XCTAssertEqual(model.status, .gone, "and never comes back to life while polling is dead")
        model.stop()
    }

    func test404AtStartIsGoneWithoutALoop() async {
        let source = FakeStopSource()
        let model = makeModel(source: source, target: StopTarget(id: "RETIRED", name: "Old Stop", lat: 53.34, lon: -6.26, mode: .bus))
        await model.start()
        XCTAssertEqual(model.status, .gone)
        await drain(source)
        XCTAssertEqual(clock.sleeperCount, 0, "no refresh loop for a stop that is gone")
        XCTAssertEqual(source.callCount, 1)
        model.stop()
    }

    func test503IsStartingAndRetriesOnTheNextTick() async {
        let source = FakeStopSource()
        await source.setError(TurasServerError.httpError(statusCode: 503))
        let model = makeModel(source: source)
        await startAndSettle(model)
        XCTAssertEqual(model.status, .starting)

        await source.setError(nil)
        clock.advance(by: 30)
        await waitUntil { model.status == .loaded }
        model.stop()
    }

    func test429IsSilent() async {
        let source = FakeStopSource()
        let model = makeModel(source: source)
        await startAndSettle(model)

        await source.setError(TurasServerError.httpError(statusCode: 429))
        clock.advance(by: 30)
        await waitUntil { source.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(model.status, .loaded, "rate limiting never shows a message")
        XCTAssertEqual(model.departures.count, 2)
        model.stop()
    }

    // MARK: - Pausing

    func testPauseForFocusSurvivesSceneChanges() async {
        let source = FakeStopSource()
        let model = makeModel(source: source)
        await startAndSettle(model)

        model.pause()
        await waitUntil("loop cancelled") { self.clock.sleeperCount == 0 }
        clock.advance(by: 90)
        await drain(source)
        XCTAssertEqual(source.callCount, 1, "no fetches under route focus")

        // The app goes to the background and comes back while focus is still open.
        model.scenePhaseChanged(to: .background)
        model.scenePhaseChanged(to: .active)
        await drain(source)
        XCTAssertEqual(source.callCount, 1, "foreground must not wake a paused stop view")
        XCTAssertEqual(clock.sleeperCount, 0)

        model.resume()
        await waitUntil("resume fetches now") { source.callCount == 2 }
        await waitUntil { self.clock.sleeperCount == 1 }
        model.resume()
        await drain(source)
        XCTAssertEqual(source.callCount, 2, "resume when not paused is a no-op")
        model.stop()
    }

    func testBackgroundPausesAndForegroundFetchesImmediately() async {
        let source = FakeStopSource()
        let model = makeModel(source: source)
        await startAndSettle(model)
        let firstUpdate = model.lastUpdated

        model.scenePhaseChanged(to: .background)
        await waitUntil("loop cancelled") { self.clock.sleeperCount == 0 }
        clock.advance(by: 3 * 3600)
        await drain(source)
        XCTAssertEqual(source.callCount, 1, "no fetches in the background")
        XCTAssertEqual(model.departures.count, 2, "stale rows stay")
        XCTAssertEqual(model.lastUpdated, firstUpdate)

        model.scenePhaseChanged(to: .active)
        await waitUntil { source.callCount == 2 }
        await waitUntil { model.lastUpdated == self.clock.now }
        model.scenePhaseChanged(to: .active)
        await drain(source)
        XCTAssertEqual(source.callCount, 2, "already in the foreground: nothing extra")
        model.stop()
    }

    // MARK: - Lifecycle

    func testStartAfterStopDoesNothing() async {
        // The stop view closed before its start task ran.
        let source = FakeStopSource()
        let model = makeModel(source: source)
        model.stop()
        await model.start()
        XCTAssertEqual(source.callCount, 0)
        XCTAssertEqual(clock.sleeperCount, 0)
        XCTAssertEqual(model.status, .loading)
    }

    func testAnswerArrivingAfterStopIsDropped() async {
        // The stop view closes while a fetch is at the source: its answer,
        // arriving afterwards, never lands.
        let source = FakeStopSource()
        let model = makeModel(source: source)
        await source.hold(collegeGreen.id)
        let fetch = Task { await model.refresh() }
        await waitUntil("fetch reached the source") { source.callCount == 1 }
        model.stop()
        await source.release(collegeGreen.id)
        await fetch.value
        XCTAssertEqual(model.departures, [], "a stopped model never applies an answer")
        XCTAssertNil(model.info)
        XCTAssertEqual(model.status, .loading)
        XCTAssertNil(model.lastUpdated)
    }

    func testFailureArrivingAfterStopIsDropped() async {
        let source = FakeStopSource()
        await source.setError(TurasServerError.httpError(statusCode: 500))
        let model = makeModel(source: source)
        await source.hold(collegeGreen.id)
        let fetch = Task { await model.refresh() }
        await waitUntil("fetch reached the source") { source.callCount == 1 }
        model.stop()
        await source.release(collegeGreen.id)
        await fetch.value
        XCTAssertEqual(model.status, .loading, "a stopped model never shows a failure")
    }

    // MARK: - Overtaken answers

    func testOvertakenFailureDoesNotReplaceFresherRows() async {
        // start()'s first fetch is slow and fails; meanwhile the app went to
        // the background and back, and the foreground fetch succeeded.
        let source = FakeStopSource()
        await source.setError(TurasServerError.httpError(statusCode: 500))
        await source.hold(collegeGreen.id)
        let model = makeModel(source: source)
        let starting = Task { await model.start() }
        await waitUntil("first fetch at the source") { source.callCount == 1 }

        await source.setError(nil)
        model.scenePhaseChanged(to: .background)
        model.scenePhaseChanged(to: .active)
        await waitUntil { model.status == .loaded }
        let freshUpdate = model.lastUpdated

        await source.release(collegeGreen.id)
        await starting.value
        XCTAssertEqual(model.status, .loaded, "the overtaken failure is dropped")
        XCTAssertEqual(model.departures.map(\.route), ["39A", "46A"])
        XCTAssertEqual(model.lastUpdated, freshUpdate)
        await waitUntil("one loop, sleeping") { self.clock.sleeperCount == 1 }
        XCTAssertEqual(source.callCount, 2)
        model.stop()
    }

    func testSlowFirstFetchKeepsTheLoopAlreadyRunning() async {
        // The foreground fetch has already started the loop; start()'s slow
        // first fetch finishing must not restart it (that would push the
        // next refresh back by however long the first fetch took).
        let source = FakeStopSource()
        await source.hold(collegeGreen.id)
        let model = makeModel(source: source)
        let starting = Task { await model.start() }
        await waitUntil("first fetch at the source") { source.callCount == 1 }

        model.scenePhaseChanged(to: .background)
        model.scenePhaseChanged(to: .active)
        await waitUntil { model.status == .loaded }
        await waitUntil("loop sleeping") { self.clock.sleeperCount == 1 }
        clock.advance(by: 20)

        await source.release(collegeGreen.id)
        await starting.value
        clock.advance(by: 10)
        await waitUntil("refresh 30 s after the foreground fetch") { source.callCount == 3 }
        model.stop()
    }

    func testOvertakenAnswerDoesNotReplaceFresherRows() async {
        // A slow answer (nothing leaving) lands after Retry's newer one.
        let source = FakeStopSource()
        let fresh = SampleData.stopDepartures(for: collegeGreen.id)
        let info = StopInfo(id: collegeGreen.id, name: "College Green", code: "400", lat: collegeGreen.lat, lon: collegeGreen.lon, modes: [.bus])
        await source.setResponse(StopDepartures(stop: info, departures: []), for: collegeGreen.id)
        await source.hold(collegeGreen.id)
        let model = makeModel(source: source)
        let starting = Task { await model.start() }
        await waitUntil("first fetch at the source") { source.callCount == 1 }

        await source.setResponse(fresh, for: collegeGreen.id)
        model.retry()
        await waitUntil { model.status == .loaded }

        await source.release(collegeGreen.id)
        await starting.value
        XCTAssertEqual(model.status, .loaded, "the overtaken answer is dropped")
        XCTAssertEqual(model.departures.map(\.route), ["39A", "46A"])
        model.stop()
    }

    func testAnswerInFlightWhenPausedIsDropped() async {
        // Route focus opens while a fetch is at the source; resume fetches afresh.
        let source = FakeStopSource()
        await source.hold(collegeGreen.id)
        let model = makeModel(source: source)
        let starting = Task { await model.start() }
        await waitUntil("first fetch at the source") { source.callCount == 1 }

        model.pause()
        await source.release(collegeGreen.id)
        await starting.value
        XCTAssertEqual(model.status, .loading, "the answer in flight at pause is dropped")
        XCTAssertNil(model.lastUpdated)
        XCTAssertEqual(clock.sleeperCount, 0, "no loop while paused")

        model.resume()
        await waitUntil { model.status == .loaded }
        XCTAssertEqual(source.callCount, 2)
        model.stop()
    }

    func testReleasedModelStopsRefreshing() async {
        let source = FakeStopSource()
        var model: StopModel? = makeModel(source: source)
        weak var released: StopModel?
        released = model
        await startAndSettle(model!)

        model = nil
        XCTAssertNil(released, "the refresh loop must not keep the model alive")
        clock.advance(by: 30)
        await waitUntil("loop exits") { self.clock.sleeperCount == 0 }
        XCTAssertEqual(source.callCount, 1, "no fetch after the model is gone")
    }

    // MARK: - Caption

    func testCaptionAndDistance() async {
        XCTAssertEqual(StopModel.caption(code: "7602", distanceMetres: 240), "Stop 7602 · 240 m")
        XCTAssertEqual(StopModel.caption(code: nil, distanceMetres: 240), "240 m")
        XCTAssertEqual(StopModel.caption(code: "7602", distanceMetres: nil), "Stop 7602")
        XCTAssertEqual(StopModel.caption(code: "", distanceMetres: nil), nil, "an empty code is not 'Stop '")
        XCTAssertEqual(StopModel.caption(code: nil, distanceMetres: 1250), "1.3 km")

        // 100 m north of the stop.
        let user = CLLocationCoordinate2D(latitude: collegeGreen.lat + 100 / 111_195, longitude: collegeGreen.lon)
        let near = makeModel(source: FakeStopSource(), userLocation: user)
        XCTAssertEqual(Double(near.distanceFromUser ?? 0), 100, accuracy: 1)
        XCTAssertEqual(near.caption, "100 m", "distance before the code is known")
        await near.start()
        XCTAssertEqual(near.caption, "Stop 400 · 100 m")
        near.stop()

        let unlocated = makeModel(source: FakeStopSource(), target: StopTarget(SampleData.abbeyStreet, mode: .luas))
        XCTAssertNil(unlocated.distanceFromUser)
        await unlocated.start()
        XCTAssertNil(unlocated.caption, "no code and no location: no caption line")
        unlocated.stop()
    }
}
