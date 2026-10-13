import MapKit
import SwiftUI

/// The home screen: the map on the top half with the search box floating
/// over it, and the timeline, search results or route focus below.
struct HomeView: View {
    @ObservedObject var model: HomeModel
    @Environment(\.scenePhase) private var scenePhase
    /// Pin labels show when the camera is close enough to read them.
    @State private var showsPinLabels = false

    private static let labelDistance: Double = 1200

    private var isInFocus: Bool {
        if case .focus = model.screen { return true }
        return false
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                mapSection
                    .frame(height: proxy.size.height / 2)
                panel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Theme.surface)
            }
        }
        .background(Theme.surface)
        .onAppear { model.onAppear() }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
    }

    // MARK: - Map

    /// Only the map runs under the status bar; the search field stays in
    /// the safe area so it never sits beneath the clock.
    private var mapSection: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea(edges: .top)
            SearchField(
                search: model.search,
                isActive: model.screen == .search,
                onBegin: model.beginSearch,
                onCancel: model.cancelSearch
            )
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            if !isInFocus {
                nearMeButton
                    .padding(Theme.gutter)
            }
        }
    }

    private var map: some View {
        Map(position: $model.cameraPosition) {
            UserAnnotation()

            if isInFocus, let focus = model.focus {
                if let shape = focus.shape {
                    MapPolyline(coordinates: shape.clCoordinates)
                        .stroke(Theme.lineColor(mode: focus.mode, route: focus.route.name).opacity(0.7), lineWidth: 4)
                }
                ForEach(focus.vehicles) { vehicle in
                    Annotation(vehicle.routeId, coordinate: vehicle.coordinate) {
                        BusAnnotationView(routeId: vehicle.routeId, bearing: vehicle.bearing, mode: vehicle.mode)
                            .accessibilityLabel(AccessibilityText.vehicle(mode: vehicle.mode, routeId: vehicle.routeId, bearing: vehicle.bearing))
                    }
                    .annotationTitles(.hidden)
                }
                if let stop = focus.highlightedStop {
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        StopPin(name: stop.name, showsLabel: true, isHighlighted: true)
                            .accessibilityLabel(AccessibilityText.stop(name: stop.name))
                            .accessibilityIdentifier("map.focusStop")
                    }
                    .annotationTitles(.hidden)
                }
            } else {
                ForEach(model.nearby.stops) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        StopPin(name: stop.name, showsLabel: showsPinLabels)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(AccessibilityText.stop(name: stop.name))
                            .accessibilityIdentifier("map.pin.\(stop.id)")
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .onEnd) { context in
            // The span lets closing route focus restore the user's zoom.
            model.mapCameraSettled(centre: context.region.center, span: context.region.span)
        }
        .onMapCameraChange(frequency: .continuous) { context in
            let close = context.camera.distance < Self.labelDistance
            if close != showsPinLabels {
                showsPinLabels = close
            }
        }
        .accessibilityIdentifier("home.map")
    }

    private var nearMeButton: some View {
        Button {
            model.goNearMe()
        } label: {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(model.canLocate ? Theme.brand : Theme.muted)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!model.canLocate)
        .accessibilityLabel("Near me")
        .accessibilityHint("Moves the map to your location")
        .accessibilityIdentifier("home.nearMe")
    }

    // MARK: - Panel

    private var isQueryEmpty: Bool {
        model.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Search results show once there is something to search for; with
    /// the box open but empty the timeline stays in view.
    private var showsSearchResults: Bool {
        model.screen == .search && !isQueryEmpty
    }

    /// Whether search results or route focus cover the timeline.
    private var coversTimeline: Bool {
        showsSearchResults || isInFocus
    }

    /// The timeline is always mounted, so its scroll position survives
    /// search and route focus: those panels cover it, and while covered it
    /// is invisible, untappable and hidden from VoiceOver (and UI tests).
    ///
    /// No identifier on this container: it would replace the identifiers
    /// of the tabs and buttons inside it.
    private var panel: some View {
        ZStack(alignment: .top) {
            VStack(spacing: Theme.cardSpacing) {
                timelinePanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(coversTimeline ? 0 : 1)
            .allowsHitTesting(!coversTimeline)
            .accessibilityHidden(coversTimeline)

            if showsSearchResults {
                SearchResultsView(
                    search: model.search,
                    mapCentre: model.centre,
                    onSelectStop: model.selectStopResult,
                    onSelectRoute: model.selectRouteResult,
                    onSelectPlace: model.selectPlaceResult
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.surface)
            } else if isInFocus, let focus = model.focus {
                RouteFocusView(focus: focus, onBack: model.closeFocus)
                    .gesture(
                        DragGesture(minimumDistance: 40)
                            .onEnded { value in
                                if value.translation.height > 80 {
                                    model.closeFocus()
                                }
                            }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Theme.surface)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var timelinePanel: some View {
        if model.showsPrimingCard {
            PrimingCard(onAllow: model.allowLocation, onNotNow: model.notNow)
                .padding(.horizontal, Theme.gutter)
        }
        if let note = model.locationNote {
            StatusBanner(kind: .info, message: note)
                .padding(.horizontal, Theme.gutter)
                .accessibilityIdentifier("home.locationNote")
        }
        ModeTabs(selected: model.mode, onSelect: model.selectMode)
            .padding(.horizontal, Theme.gutter)
        DepartureTimeline(
            nearby: model.nearby,
            mode: model.mode,
            onSelect: { model.openFocus(departure: $0) },
            onRetry: model.nearby.retry
        )
    }
}
