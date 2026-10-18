import XCTest
@testable import Turas

@MainActor
final class StationStoreTests: XCTestCase {
    func testFetchesEachRailModeOnceAndNeverBus() async {
        let source = FakeStationSource()
        let store = StationStore(source: source)
        XCTAssertNil(store.stations(for: .luas))
        XCTAssertFalse(store.isLoading(.luas))

        store.load(.bus)
        store.load(.luas)
        XCTAssertTrue(store.isLoading(.luas))
        store.load(.luas) // in flight: no second request
        await waitUntil("luas loaded") { store.stations(for: .luas) != nil }
        XCTAssertEqual(store.stations(for: .luas)?.map(\.name), ["Abbey Street", "Jervis"])
        XCTAssertFalse(store.isLoading(.luas))

        store.load(.luas) // loaded: kept for the session
        store.load(.train)
        await waitUntil("train loaded") { store.stations(for: .train) != nil }
        XCTAssertEqual(store.stations(for: .train)?.map(\.id), ["IR-CON", "IR-TARA"])
        let modes = await source.modes
        XCTAssertEqual(modes, [.luas, .train], "bus never asks; each rail mode once")
        XCTAssertNil(store.stations(for: .bus))
    }

    func testFailureLeavesNothingAndTheNextLoadRetries() async {
        let source = FakeStationSource()
        await source.setError(URLError(.notConnectedToInternet))
        let store = StationStore(source: source)

        store.load(.train)
        await waitUntil("fetch finished") { !store.isLoading(.train) }
        XCTAssertNil(store.stations(for: .train), "nothing stored: the map falls back to /nearby's stops")
        XCTAssertEqual(source.callCount, 1)

        await source.setError(nil)
        store.load(.train)
        await waitUntil("retried") { store.stations(for: .train) != nil }
        XCTAssertEqual(source.callCount, 2)
    }

    func testEmptyListCountsAsNotLoaded() async {
        let source = FakeStationSource()
        await source.setStations([], for: .luas)
        let store = StationStore(source: source)

        store.load(.luas)
        await waitUntil { !store.isLoading(.luas) }
        XCTAssertNil(store.stations(for: .luas), "an empty list would leave the map without pins")

        await source.setStations(SampleData.stations(mode: .luas), for: .luas)
        store.load(.luas)
        await waitUntil { store.stations(for: .luas) != nil }
        XCTAssertEqual(source.callCount, 2)
    }
}
