import CoreLocation
import Foundation

/// System location with approximate accuracy (kCLLocationAccuracyReduced). Used only when the
/// user picks "system location"; manual cities never touch CoreLocation.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []
    private var timeoutWork: DispatchWorkItem?
    private var cachedName: (latitude: Double, longitude: Double, name: String)?
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    var isAuthorized: Bool { authorization.rawValue == 3 || authorization.rawValue == 4 }
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

    func requestAuthorization() {
        guard authorization == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func currentLocation() async throws -> CLLocation {
        if let recent = manager.location, abs(recent.timestamp.timeIntervalSinceNow) < 600 {
            return recent
        }
        switch authorization {
        case .denied, .restricted:
            throw LiveSkyError.location(L("error.location.denied"))
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 {
                manager.requestLocation()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.finish(.failure(LiveSkyError.location(L("error.location.timeout"))))
                    }
                }
                timeoutWork = work
                // Leave time for the permission prompt on first use.
                DispatchQueue.main.asyncAfter(deadline: .now() + (authorization == .notDetermined ? 120 : 30), execute: work)
            }
        }
    }

    /// City name for display only, resolved by Apple's geocoder and cached per location.
    func placeName(for location: CLLocation) async -> String {
        let latitude = location.coordinate.latitude, longitude = location.coordinate.longitude
        if let cached = cachedName, abs(cached.latitude - latitude) < 0.05, abs(cached.longitude - longitude) < 0.05 {
            return cached.name
        }
        let name: String
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
           let locality = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? placemark.name {
            name = locality
        } else {
            name = L("location.current")
        }
        cachedName = (latitude, longitude, name)
        return name
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(with: result) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated {
            if code == .denied {
                finish(.failure(LiveSkyError.location(L("error.location.denied"))))
            } else {
                finish(.failure(LiveSkyError.location(L("error.location.unavailable"))))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if isAuthorized, !waiting.isEmpty { self.manager.requestLocation() }
            if authorization == .denied || authorization == .restricted {
                finish(.failure(LiveSkyError.location(L("error.location.denied"))))
            }
            onAuthorizationChange?()
        }
    }
}
