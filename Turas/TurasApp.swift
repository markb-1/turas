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
                ContentView(dependencies: dependencies)
            } else {
                ServerNotConfiguredView()
            }
        }
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

    init(config: ServerConfig) {
        let serverService = TurasServerService(config: config)
        let routeStopService = RouteStopService()
        self.serverService = serverService
        self.locationService = LocationService()
        self.routeShapeService = RouteShapeService()
        self.routeStopService = routeStopService
        self.staticData = StaticDataStore(source: serverService, bundledStops: routeStopService)
        self.favourites = FavouritesStore()
    }
}
