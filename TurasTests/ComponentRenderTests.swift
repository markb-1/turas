import Combine
import CoreLocation
import SwiftUI
import XCTest
@testable import Turas

/// Hosts each component once so a crash in a body (a missing colour set,
/// a force unwrap) fails here instead of on a device. Layout is not
/// asserted; the UI smoke test takes screenshots.
@MainActor
final class ComponentRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_630_000)

    private func render<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(controller.view.bounds.width, 0, file: file, line: line)
    }

    private var departure: NearbyDeparture {
        NearbyDeparture(route: "39A", agencyId: "1", direction: 0, headsign: "Ongar", stopId: "S", distanceM: 90, times: [
            DepartureTime(tripId: "a", at: now.addingTimeInterval(120), delay: 0, source: .live, cancelled: false),
            DepartureTime(tripId: "b", at: now.addingTimeInterval(14 * 60), delay: 0, source: .realtime, cancelled: false),
            DepartureTime(tripId: "c", at: now.addingTimeInterval(27 * 60), delay: 0, source: .timetable, cancelled: true),
        ])
    }

    func testComponentsRender() async {
        render(RouteBadge(route: "39A", mode: .bus))
        render(RouteBadge(route: "Green", mode: .luas))
        render(TimeStack(times: departure.times, now: now))
        render(TimeStack(times: [], now: now))
        render(DepartureCard(departure: departure, stopName: "College Green", mode: .bus, now: now))
        render(DepartureCard(departure: departure, stopName: "College Green", mode: .bus, now: now).dynamicTypeSize(.accessibility5))
        render(DepartureCard(departure: departure, stopName: nil, mode: .bus, now: now, identifierPrefix: "stop.row"))
        render(CentreMarker(isLifted: false))
        render(CentreMarker(isLifted: true))
        render(StopPin(name: "College Green", showsLabel: true, isHighlighted: true))
        render(ModeTabs(selected: .luas, onSelect: { _ in }))
        let search = SearchModel(source: FakeSearchSource(), places: NoPlaceSearch(), clock: ManualClock().appClock)
        render(SearchField(search: search, isActive: true, onBegin: {}, onCancel: {}))
        render(PrimingCard(onAllow: {}, onNotNow: {}))
        render(StatusBanner(kind: .warning, message: "Updated 3 min ago", actionTitle: "Retry", action: {}))
        render(StatusBanner(kind: .progress, message: "Turas is starting up…"))
        render(BusAnnotationView(routeId: "DART", bearing: 90, mode: .train))
    }
    func testTimelineEmptyMessageNamesTheRadius() {
        XCTAssertEqual(DepartureTimeline.emptyMessage(for: .bus), "Nothing leaving within 300 m in the next 90 min. Try another mode or move the map.")
        XCTAssertEqual(DepartureTimeline.emptyMessage(for: .luas), "Nothing leaving within 800 m in the next 90 min. Try another mode or move the map.")
        XCTAssertEqual(DepartureTimeline.emptyMessage(for: .train), "Nothing leaving within 800 m in the next 90 min. Try another mode or move the map.")
    }

    func testPanelsRender() async {
        let clock = ManualClock()
        let nearby = NearbyModel(source: FakeNearbySource(), clock: clock.appClock)
        render(DepartureTimeline(nearby: nearby, mode: .bus, onSelect: { _ in }, onRetry: {}))

        let centre = CLLocationCoordinate2D(latitude: 53.34, longitude: -6.26)
        let search = SearchModel(source: FakeSearchSource(), places: NoPlaceSearch(), clock: clock.appClock)
        render(SearchResultsView(search: search, mapCentre: centre, onSelectStop: { _ in }, onSelectRoute: { _ in }, onSelectPlace: { _ in }))

        let target = RouteFocusTarget(route: RouteRef(name: "39A", agencyId: "1"), mode: .bus, direction: 0, headsign: "Ongar", stop: nil)
        let store = StaticDataStore(source: EmptyStaticSource(), bundledStops: RouteStopService(stopsByRoute: [:]), cacheDirectory: nil, bundledRoutes: { [:] })
        let focus = RouteFocusModel(target: target, centre: centre, userLocation: nil,
                                    source: FakeFocusSource(), staticData: store, shapes: RouteShapeService(shapes: [:]), clock: clock.appClock, headsignLookup: [:])
        render(RouteFocusView(focus: focus, onBack: {}))
        let stop = StopModel(target: StopTarget(SampleData.collegeGreen, mode: .bus), userLocation: nil,
                             source: FakeStopSource(), clock: clock.appClock)
        render(StopView(stop: stop, onBack: {}, onSelect: { _ in }))
        render(RouteFocusView(focus: focus, onBack: {}, backLabel: "Back to stop"))
    }

    func testHomeViewRendersEveryScreen() async {
        let clock = ManualClock()
        let nearby = NearbyModel(source: FakeNearbySource(), clock: clock.appClock)
        let search = SearchModel(source: FakeSearchSource(), places: NoPlaceSearch(), clock: clock.appClock)
        let store = StaticDataStore(source: EmptyStaticSource(), bundledStops: RouteStopService(stopsByRoute: [:]), cacheDirectory: nil, bundledRoutes: { [:] })
        let model = HomeModel(nearby: nearby, search: search, stations: StationStore(source: FakeStationSource()), location: RenderLocation(), makeFocus: { target, centre, userLocation in
            RouteFocusModel(target: target, centre: centre, userLocation: userLocation, source: FakeFocusSource(),
                            staticData: store, shapes: RouteShapeService(shapes: [:]), clock: clock.appClock, headsignLookup: [:])
        }, makeStop: { target, userLocation in
            StopModel(target: target, userLocation: userLocation, source: FakeStopSource(), clock: clock.appClock)
        })
        render(HomeView(model: model)) // timeline: marker, circle, pins

        // A stop reached by search: its highlighted pin is drawn (HomeModelTests cover mapPins).
        model.openStop(StopTarget(SampleData.taraStreet, mode: .train))
        await waitUntil { model.stop?.status == .loaded }
        render(HomeView(model: model)) // stop view

        model.openFocus(departure: model.stop!.departures[0])
        render(HomeView(model: model)) // focus over the stop view
        model.closeFocus()
        model.closeStop()
        render(HomeView(model: model))
    }

    func testStopSubtitleShowsModesAndDistanceFromCentre() {
        let centre = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2600)
        let near = StopSearchResult(id: "a", name: "Dun Laoghaire SC", lat: 53.3409, lon: -6.2600, modes: [.bus])
        XCTAssertEqual(SearchResultsView.stopSubtitle(near, from: centre), "Bus · 100 m")
        let far = StopSearchResult(id: "b", name: "Dun Laoghaire SC", lat: 53.3500, lon: -6.2600, modes: [.bus, .luas])
        XCTAssertEqual(SearchResultsView.stopSubtitle(far, from: centre), "Bus · Luas · 1.1 km")
        let none = StopSearchResult(id: "c", name: "X", lat: 53.3409, lon: -6.2600, modes: [])
        XCTAssertEqual(SearchResultsView.stopSubtitle(none, from: centre), "100 m")
    }

    func testStopLabelSpeaksSeparatorsAndUnits() {
        let centre = CLLocationCoordinate2D(latitude: 53.3400, longitude: -6.2600)
        let near = StopSearchResult(id: "a", name: "Dun Laoghaire SC", lat: 53.3409, lon: -6.2600, modes: [.bus])
        XCTAssertEqual(SearchResultsView.stopLabel(near, from: centre), "Stop, Dun Laoghaire SC, Bus, 100 metres")
        let far = StopSearchResult(id: "b", name: "Dun Laoghaire SC", lat: 53.3500, lon: -6.2600, modes: [.bus, .luas])
        XCTAssertEqual(SearchResultsView.stopLabel(far, from: centre), "Stop, Dun Laoghaire SC, Bus, Luas, 1.1 kilometres")
    }
}

private actor NoPlaceSearch: PlaceSearching {
    func searchPlaces(_ query: String) async throws -> [PlaceResult] { [] }
}

private actor EmptyStaticSource: StaticDataSource {
    func fetchRoutes(mode: TransportMode) async throws -> [TransitRoute] { [] }
    func fetchStops(route: String, agency: String?, direction: Int) async throws -> [RouteStop] { [] }
}

@MainActor
private final class RenderLocation: LocationProviding {
    var userLocation: CLLocationCoordinate2D? { nil }
    var authorizationStatus: CLAuthorizationStatus { .denied }
    var authorizationStatusPublisher: AnyPublisher<CLAuthorizationStatus, Never> { Just(.denied).eraseToAnyPublisher() }
    var userLocationPublisher: AnyPublisher<CLLocationCoordinate2D?, Never> { Just(nil).eraseToAnyPublisher() }
    func requestLocation() async -> CLLocationCoordinate2D? { nil }
}
