import SwiftUI

/// App entry point.
///
/// Key SwiftUI concept: `@main` marks this as the app's entry point.
/// The `App` protocol requires a single `body` that returns a `Scene`.
/// `WindowGroup` is the standard scene for an iOS app — it manages
/// a single window containing your root view.
///
/// We create our services here at the top level and pass them down.
/// This is simple dependency injection — no frameworks needed.
@main
struct TurasApp: App {
    private let serverService: TurasServerService
    private let locationService: LocationService
    private let routeShapeService: RouteShapeService
    private let routeStopService: RouteStopService

    init() {
        self.serverService = TurasServerService()
        self.locationService = LocationService()
        self.routeShapeService = RouteShapeService()
        self.routeStopService = RouteStopService()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                serverService: serverService,
                locationService: locationService,
                routeShapeService: routeShapeService,
                routeStopService: routeStopService
            )
        }
    }
}
