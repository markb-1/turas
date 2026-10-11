import SwiftUI

/// App entry point.
///
/// Services are created once here and passed down (simple dependency
/// injection, no frameworks). A build without server settings shows
/// ServerNotConfiguredView instead of the map (Debug builds stop earlier,
/// in Config).
@main
@MainActor
struct TurasApp: App {
    private let dependencies: AppDependencies?

    init() {
        dependencies = Config.server.map { AppDependencies(config: $0) }
    }

    var body: some Scene {
        WindowGroup {
            if let dependencies {
                HomeRoot(dependencies: dependencies)
            } else {
                ServerNotConfiguredView()
            }
        }
    }
}

/// Owns the HomeModel for the app's lifetime (a StateObject must live in a
/// view, not in the App).
private struct HomeRoot: View {
    @StateObject private var model: HomeModel

    init(dependencies: AppDependencies) {
        _model = StateObject(wrappedValue: dependencies.makeHomeModel())
    }

    var body: some View {
        HomeView(model: model)
    }
}

/// Long-lived services shared by the whole app.
@MainActor
final class AppDependencies {
    let serverService: TurasServerService
    let locationService: LocationService
    let routeShapeService: RouteShapeService
    let routeStopService: RouteStopService
    let staticData: StaticDataStore
    let favourites: FavouritesStore
    let placeSearch: PlaceSearching

    init(config: ServerConfig, environment: [String: String] = ProcessInfo.processInfo.environment) {
        var session: URLSession?
        var placeSearch: PlaceSearching = MapKitPlaceSearch()
        #if DEBUG
        if Self.isUITestStub(environment) {
            session = UITestStubServer.session()
            placeSearch = UITestStubPlaceSearch()
        }
        #endif
        let serverService = TurasServerService(config: config, session: session)
        let routeStopService = RouteStopService()
        self.serverService = serverService
        self.placeSearch = placeSearch
        self.locationService = LocationService()
        self.routeShapeService = RouteShapeService()
        self.routeStopService = routeStopService
        self.staticData = StaticDataStore(
            source: serverService,
            bundledStops: routeStopService,
            cacheDirectory: Self.staticDataCacheDirectory(environment: environment)
        )
        self.favourites = FavouritesStore()
    }

    /// Where StaticDataStore caches routes and stops. A UI-test stub run
    /// keeps them in memory only: canned answers on disk would outlive the
    /// run by 7 days and show up in later live runs.
    nonisolated static func staticDataCacheDirectory(environment: [String: String]) -> URL? {
        #if DEBUG
        if isUITestStub(environment) { return nil }
        #endif
        return StaticDataStore.defaultCacheDirectory()
    }

    #if DEBUG
    /// Launched by the UI tests against the in-app stub server.
    nonisolated static func isUITestStub(_ environment: [String: String]) -> Bool {
        environment["TURAS_UITEST_STUB"] == "1"
    }
    #endif

    /// The home screen's models, wired to the live services.
    func makeHomeModel() -> HomeModel {
        let nearby = NearbyModel(source: serverService)
        let search = SearchModel(source: serverService, places: placeSearch)
        let serverService = serverService
        let staticData = staticData
        let routeShapeService = routeShapeService
        // Decode the bundled shapes and stops off the main thread now, so the
        // first route focus does not hitch, and refresh stale route lists as
        // the old map screen did at launch.
        Task.detached(priority: .utility) { [routeShapeService, routeStopService, staticData] in
            await routeShapeService.preload()
            await routeStopService.preload()
            await staticData.refreshRoutesIfStale()
        }
        return HomeModel(nearby: nearby, search: search, location: locationService) { target, centre, userLocation in
            RouteFocusModel(
                target: target, centre: centre, userLocation: userLocation,
                source: serverService, staticData: staticData, shapes: routeShapeService
            )
        }
    }
}
