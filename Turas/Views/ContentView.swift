import SwiftUI
import MapKit

/// The root view — a full-screen map with live bus annotations.
///
/// Key SwiftUI concepts:
/// - `@StateObject`: Creates and owns the ViewModel. Use this in the view
///   that *creates* the object. Child views use `@ObservedObject` instead.
/// - `Map` (iOS 17+): SwiftUI-native map that takes a `MapCameraPosition` binding
///   and renders content via a `MapContentBuilder`.
/// - `.sheet`: Presents a modal bottom sheet. The `presentationDetents`
///   modifier controls how tall the sheet can be.
struct ContentView: View {
    @StateObject private var viewModel: MapViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let serverService: TurasServerService

    init(dependencies: AppDependencies) {
        self.serverService = dependencies.serverService
        _viewModel = StateObject(wrappedValue: MapViewModel(
            serverService: dependencies.serverService,
            locationService: dependencies.locationService,
            routeShapeService: dependencies.routeShapeService,
            routeStopService: dependencies.routeStopService
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapView

            if viewModel.isLoading && viewModel.selection != .idle && viewModel.vehicles.isEmpty {
                loadingOverlay
            }

            if let error = viewModel.errorMessage, viewModel.vehicles.isEmpty {
                errorOverlay(error)
            }

            RouteSearchBar(viewModel: viewModel)
        }
        .onAppear { viewModel.onAppear() }
        .onChange(of: scenePhase) { _, phase in
            viewModel.scenePhaseChanged(to: phase)
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            switch sheet {
            case .vehicle(let vehicle):
                BusDetailSheet(vehicle: vehicle)
                    .presentationDetents([.fraction(0.25), .medium])
                    .presentationDragIndicator(.visible)
            case .stop(let stop):
                StopDetailSheet(
                    stop: stop,
                    routeName: viewModel.selectedRouteName ?? "",
                    direction: viewModel.selectedDirection ?? 0,
                    mode: viewModel.selectedMode,
                    serverService: serverService
                )
                .presentationDetents([.fraction(0.3), .medium])
                .presentationDragIndicator(.visible)
            case .nearbyStop(let nearbyStop):
                NearbyStopSheet(
                    nearbyStop: nearbyStop,
                    mode: viewModel.selectedMode,
                    onSelectRoute: { route in
                        viewModel.activeSheet = nil
                        viewModel.selectRoute(route)
                    }
                )
                .presentationDetents([.fraction(0.3), .medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Subviews

    private var mapView: some View {
        Map(position: $viewModel.cameraPosition) {
            // UserAnnotation shows the blue dot if location is authorized
            UserAnnotation()

            // Route shape polylines (drawn under annotations)
            ForEach(Array(viewModel.activeRouteShapes.enumerated()), id: \.offset) { _, shape in
                MapPolyline(coordinates: shape.clCoordinates)
                    .stroke(viewModel.activeRouteColor.opacity(0.5), lineWidth: 4)
            }

            // Nearby stop dots (idle state — no route selected)
            ForEach(viewModel.nearbyStops) { nearbyStop in
                Annotation(
                    nearbyStop.stop.name,
                    coordinate: nearbyStop.coordinate
                ) {
                    StopAnnotationView(modeColor: viewModel.selectedMode.color)
                        .onTapGesture {
                            viewModel.selectNearbyStop(nearbyStop)
                        }
                }
                .annotationTitles(.hidden)
            }

            // Stop dots along the selected direction
            ForEach(viewModel.activeRouteStops) { stop in
                Annotation(
                    stop.name,
                    coordinate: stop.coordinate
                ) {
                    StopAnnotationView(
                        isClosest: stop.id == viewModel.closestStop?.id,
                        stopName: stop.id == viewModel.closestStop?.id ? stop.name : nil,
                        walkingMinutes: stop.id == viewModel.closestStop?.id ? viewModel.walkingMinutes : nil,
                        modeColor: viewModel.activeRouteColor
                    )
                    .onTapGesture {
                        viewModel.selectStop(stop)
                    }
                }
                .annotationTitles(.hidden)
            }

            ForEach(viewModel.displayedVehicles) { vehicle in
                Annotation(
                    vehicle.routeId,
                    coordinate: vehicle.coordinate
                ) {
                    BusAnnotationView(routeId: vehicle.routeId, bearing: vehicle.bearing, mode: vehicle.mode)
                        .onTapGesture {
                            viewModel.selectVehicle(vehicle)
                        }
                }
                .annotationTitles(.hidden) // We show route in our custom view
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea(edges: .top)
    }

    private var loadingOverlay: some View {
        VStack {
            ProgressView()
                .controlSize(.large)
            Text("Loading \(viewModel.selectedMode.label.lowercased()) data…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Unable to load data")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
