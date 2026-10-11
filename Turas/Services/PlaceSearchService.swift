import MapKit

/// Where SearchModel gets places. MapKit in the app; a fake in tests.
protocol PlaceSearching: Sendable {
    func searchPlaces(_ query: String) async throws -> [PlaceResult]
}

/// Apple local search, limited to Ireland. Runs on the device; the server
/// never sees place queries.
struct MapKitPlaceSearch: PlaceSearching {
    /// A region covering the island; MapKit prefers results inside it.
    static let ireland = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.4, longitude: -8.0),
        span: MKCoordinateSpan(latitudeDelta: 4.5, longitudeDelta: 6.0)
    )

    init() {}

    func searchPlaces(_ query: String) async throws -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = Self.ireland
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            guard let name = item.name, !name.isEmpty else { return nil }
            let coordinate = item.placemark.coordinate
            let subtitle = [item.placemark.thoroughfare, item.placemark.locality]
                .compactMap { $0 }
                .joined(separator: ", ")
            return PlaceResult(
                id: "\(name)|\(coordinate.latitude)|\(coordinate.longitude)",
                name: name,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )
        }
    }
}
