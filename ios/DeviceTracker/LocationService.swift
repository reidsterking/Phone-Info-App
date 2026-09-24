import CoreLocation
import Foundation

/// Wraps CLLocationManager. Significant-change monitoring is always on because it lets iOS wake
/// (or relaunch) the app when the device moves roughly 500m, at very little battery cost.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus

    /// Called on the main thread for every new location.
    var onUpdate: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private var waiters: [(CLLocation?) -> Void] = []

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = false
        lastLocation = manager.location
    }

    var hasAlwaysPermission: Bool { authorization == .authorizedAlways }
    private var hasAnyPermission: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // iOS requires asking for "While Using" first. We upgrade to "Always" once that is granted.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func start() {
        guard hasAnyPermission else { return }
        let continuous = Settings.shared.continuousTracking
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = continuous
        manager.startMonitoringSignificantLocationChanges()
        if continuous {
            manager.distanceFilter = 25
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    /// Returns a location no older than 15 seconds if one arrives within `timeout`,
    /// otherwise the best location we already have.
    func currentLocation(timeout: TimeInterval = 10) async -> CLLocation? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                if let location = self.lastLocation, location.timestamp.timeIntervalSinceNow > -15 {
                    continuation.resume(returning: location)
                    return
                }
                guard self.hasAnyPermission else {
                    continuation.resume(returning: self.lastLocation)
                    return
                }
                var finished = false
                let finish: (CLLocation?) -> Void = { location in
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: location)
                }
                self.waiters.append(finish)
                self.manager.requestLocation()
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    finish(self?.lastLocation)
                }
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        start()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        flushWaiters(with: location)
        onUpdate?(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        flushWaiters(with: lastLocation)
    }

    private func flushWaiters(with location: CLLocation?) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(location) }
    }
}
