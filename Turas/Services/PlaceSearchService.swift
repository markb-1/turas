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

    /// Addresses and points of interest are asked for in two requests: in
    /// one request, MapKit geocodes a bare well-known name ("Phoenix",
    /// "Boston") to the city abroad whatever the region, and the Irish
    /// points of interest never come back. Areas ("Dundrum", "Howth") still
    /// need the address request.
    func searchPlaces(_ query: String) async throws -> [PlaceResult] {
        async let addresses = Self.search(query, types: .address)
        async let pointsOfInterest = Self.search(query, types: .pointOfInterest)
        return try await Self.merge(addresses: addresses, pointsOfInterest: pointsOfInterest)
    }

    /// Addresses first, then points of interest, each place once. One
    /// failed request leaves the other's results; only both failing throws.
    nonisolated static func merge(
        addresses: Result<[PlaceResult], Error>,
        pointsOfInterest: Result<[PlaceResult], Error>
    ) throws -> [PlaceResult] {
        if case .failure(let error) = addresses, case .failure = pointsOfInterest {
            throw error
        }
        var seen = Set<String>()
        let all = ((try? addresses.get()) ?? []) + ((try? pointsOfInterest.get()) ?? [])
        return all.filter { seen.insert($0.id).inserted }
    }

    private static func search(_ query: String, types: MKLocalSearch.ResultType) async -> Result<[PlaceResult], Error> {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = ireland
        request.resultTypes = types
        do {
            let response = try await MKLocalSearch(request: request).start()
            return .success(response.mapItems.compactMap(PlaceResult.init(mapItem:)))
        } catch {
            return .failure(error)
        }
    }
}

private extension PlaceResult {
    /// A named map item; nil without a name.
    init?(mapItem item: MKMapItem) {
        guard let name = item.name, !name.isEmpty else { return nil }
        let coordinate = item.placemark.coordinate
        let subtitle = [item.placemark.thoroughfare, item.placemark.locality]
            .compactMap { $0 }
            .joined(separator: ", ")
        self.init(
            id: "\(name)|\(coordinate.latitude)|\(coordinate.longitude)",
            name: name,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            lat: coordinate.latitude,
            lon: coordinate.longitude
        )
    }
}
