import Foundation
import CoreLocation

/// Wraps CLLocationManager to request user location for map centering.
///
/// Key iOS concept: CLLocationManager requires an NSObject delegate.
/// This is one place where we bridge to the older delegate pattern
/// from SwiftUI's async world. We use a continuation to make the
/// one-shot location request feel async/await.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var userLocation: CLLocationCoordinate2D?
    @Published var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters // Battery-friendly
    }

    /// Requests location permission and returns the user's location once.
    /// Returns nil if permission is denied or location unavailable.
    func requestLocation() async -> CLLocationCoordinate2D? {
        let status = manager.authorizationStatus

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Wait briefly for the authorization callback
            try? await Task.sleep(for: .seconds(0.5))
        }

        guard manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.first?.coordinate
        DispatchQueue.main.async {
            self.userLocation = coordinate
        }
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
        }
    }
}
