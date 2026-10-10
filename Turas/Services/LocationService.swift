import CoreLocation
import Foundation

/// Wraps CLLocationManager so the rest of the app can ask for the user's
/// location with async/await.
///
/// The class is main-actor isolated and the manager is created on the main
/// thread, so Core Location delivers delegate callbacks on the main thread
/// too (it uses the run loop of the thread that created the manager). The
/// delegate methods are `nonisolated` to satisfy the Objective-C protocol and
/// step back into main-actor state with `MainActor.assumeIsolated`.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var userLocation: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager: CLLocationManager

    /// Callers waiting for the user to answer the permission prompt.
    private var authorizationWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    /// Callers waiting for a location fix. Concurrent callers share one
    /// request and all receive the same result.
    private var locationWaiters: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters // Battery-friendly
    }

    /// Asks for permission if needed, then returns the user's location once.
    /// Returns nil if permission is denied or no fix is available.
    func requestLocation() async -> CLLocationCoordinate2D? {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        guard Self.isAuthorized(status) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 {
                manager.requestLocation()
            }
        }
    }

    /// Shows the permission prompt and waits for the answer, which arrives in
    /// locationManagerDidChangeAuthorization.
    private func requestAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            if authorizationWaiters.count == 1 {
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    // MARK: - Delegate handling (main actor)

    private func finishLocationRequest(with coordinate: CLLocationCoordinate2D?) {
        if let coordinate {
            userLocation = coordinate
        }
        let waiters = locationWaiters
        locationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: coordinate)
        }
    }

    private func authorizationDidChange(to status: CLAuthorizationStatus) {
        authorizationStatus = status
        // The manager also reports .notDetermined when it is created; only a
        // real answer releases the waiters.
        guard status != .notDetermined else { return }
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        MainActor.assumeIsolated {
            finishLocationRequest(with: coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            finishLocationRequest(with: nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorizationDidChange(to: status)
        }
    }
}
