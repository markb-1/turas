import XCTest
@testable import Turas

final class FavouritesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "FavouritesStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func entry(_ name: String, mode: TransportMode = .bus, agency: String? = "5249", direction: Int? = nil) -> SavedRoute {
        SavedRoute(mode: mode, route: RouteRef(name: name, agencyId: agency), direction: direction, agencyName: nil)
    }

    @MainActor
    func testRecentsAreMostRecentFirstAndDeduplicated() {
        let store = FavouritesStore(defaults: defaults)
        store.recordSelection(entry("39A"))
        store.recordSelection(entry("46A"))
        store.recordSelection(entry("39A", direction: 1))

        XCTAssertEqual(store.recents.map(\.route.name), ["39A", "46A"])
        XCTAssertEqual(store.recents.first?.direction, 1, "the later selection replaces the earlier one")
    }

    @MainActor
    func testRecentsAreCapped() {
        let store = FavouritesStore(defaults: defaults)
        for i in 0..<(FavouritesStore.maxRecents + 5) {
            store.recordSelection(entry("R\(i)"))
        }
        XCTAssertEqual(store.recents.count, FavouritesStore.maxRecents)
        XCTAssertEqual(store.recents.first?.route.name, "R\(FavouritesStore.maxRecents + 4)")
    }

    @MainActor
    func testSameNameDifferentAgencyAreDifferentEntries() {
        let store = FavouritesStore(defaults: defaults)
        store.recordSelection(entry("220", agency: "5249"))
        store.recordSelection(entry("220", agency: "5401"))
        XCTAssertEqual(store.recents.count, 2)
    }

    @MainActor
    func testStarToggleAndPerModeFilter() {
        let store = FavouritesStore(defaults: defaults)
        let bus = entry("39A", direction: 0)
        let luas = entry("Green", mode: .luas, agency: "5242")

        store.toggleStar(bus)
        store.toggleStar(luas)
        XCTAssertTrue(store.isStarred(bus))
        XCTAssertTrue(store.isStarred(entry("39A", direction: 1)), "starring is per route, not per direction")
        XCTAssertEqual(store.starred(for: .bus), [bus])
        XCTAssertEqual(store.starred(for: .luas), [luas])

        store.toggleStar(bus)
        XCTAssertFalse(store.isStarred(bus))
        XCTAssertEqual(store.starred, [luas])
    }

    @MainActor
    func testPersistsAcrossInstances() {
        let first = FavouritesStore(defaults: defaults)
        first.recordSelection(entry("39A", direction: 1))
        first.toggleStar(entry("46A"))

        let second = FavouritesStore(defaults: defaults)
        XCTAssertEqual(second.recents, first.recents)
        XCTAssertEqual(second.starred.map(\.route.name), ["46A"])
    }
}
