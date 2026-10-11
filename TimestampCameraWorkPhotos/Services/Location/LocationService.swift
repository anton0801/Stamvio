import CoreLocation
import Foundation
import Observation

/// A measurement captured for one specific shot.
struct LocationFix: Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let measuredAt: Date
    let reducedAccuracy: Bool

    init(location: CLLocation, reducedAccuracy: Bool) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
        measuredAt = location.timestamp
        self.reducedAccuracy = reducedAccuracy
    }

    init(latitude: Double, longitude: Double, horizontalAccuracy: Double, measuredAt: Date, reducedAccuracy: Bool) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.measuredAt = measuredAt
        self.reducedAccuracy = reducedAccuracy
    }

    func applied(to location: inout PhotoLocation) {
        location.latitude = latitude
        location.longitude = longitude
        location.horizontalAccuracy = horizontalAccuracy
        location.measuredAt = measuredAt
        location.accuracyAuthorization = reducedAccuracy ? .reduced : .full
        location.source = .device
        location.fixStatus = .attached
    }
}

/// When-In-Use location only while the camera is visible and the user turned location on (GEO-01).
/// No "Always", no background tracking. Updates stop when the camera closes, location is turned off,
/// or the app goes to the background.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Phase: Equatable {
        case off
        /// Enabled and allowed; measuring starts when the camera opens.
        case idle
        case needsPermission
        case denied
        case restricted
        case locating
        case ready
        /// No measurement within 10 s. Photos are still saved; Retry restarts measuring.
        case unavailable
    }

    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus
    private(set) var reducedAccuracy: Bool
    private(set) var latest: CLLocation?
    private(set) var phase: Phase = .off
    private(set) var isUpdating = false

    /// Mirrors the user's preference (AppPreferences.locationEnabled).
    var isEnabled = false {
        didSet { if oldValue != isEnabled { reevaluate() } }
    }

    /// True while the camera screen is visible and the app is active.
    private var isCameraActive = false
    private var timeoutTask: Task<Void, Never>?
    private var waiters: [UUID: (shutter: Date, continuation: CheckedContinuation<LocationFix?, Never>)] = [:]

    override init() {
        authorization = manager.authorizationStatus
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Called after the explicit user action of enabling location.
    func requestPermissionIfNeeded() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func setCameraActive(_ active: Bool) {
        guard isCameraActive != active else { return }
        isCameraActive = active
        reevaluate()
    }

    func retry() {
        stopUpdates()
        reevaluate()
    }

    private func reevaluate() {
        guard isEnabled else {
            stopUpdates()
            phase = .off
            return
        }
        switch authorization {
        case .notDetermined:
            stopUpdates()
            phase = .needsPermission
        case .denied:
            stopUpdates()
            phase = .denied
        case .restricted:
            stopUpdates()
            phase = .restricted
        default:
            if isCameraActive {
                startUpdates()
            } else {
                stopUpdates()
                phase = .idle
            }
        }
    }

    private func startUpdates() {
        guard !isUpdating else { return }
        isUpdating = true
        phase = .locating
        manager.startUpdatingLocation()
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LocationPolicy.waitAfterShutter * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.isUpdating, self.currentFreshFix(at: Date()) == nil { self.phase = .unavailable }
        }
    }

    private func stopUpdates() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if isUpdating { manager.stopUpdatingLocation() }
        isUpdating = false
        resolveAllWaiters()
    }

    /// The latest measurement if it qualifies for a shot at `shutter` (≤ 30 s old, valid accuracy).
    func currentFreshFix(at shutter: Date) -> LocationFix? {
        guard let latest else { return nil }
        let evaluation = LocationPolicy.evaluate(measuredAt: latest.timestamp, horizontalAccuracy: latest.horizontalAccuracy,
                                                 reducedAccuracy: reducedAccuracy, shutter: shutter)
        switch evaluation {
        case .precise, .approximate: return LocationFix(location: latest, reducedAccuracy: reducedAccuracy)
        case .stale, .invalid: return nil
        }
    }

    /// Waits up to 10 s after the shutter for a measurement taken within the allowed window.
    /// Never returns a measurement taken later than the window (A05: later GPS never moves an old photo).
    func waitForFix(shutter: Date) async -> LocationFix? {
        if let fix = currentFreshFix(at: shutter) { return fix }
        guard isEnabled, isAuthorized, isUpdating else { return nil }
        let id = UUID()
        let deadline = shutter.addingTimeInterval(LocationPolicy.waitAfterShutter)
        return await withCheckedContinuation { (continuation: CheckedContinuation<LocationFix?, Never>) in
            waiters[id] = (shutter, continuation)
            Task { [weak self] in
                let delay = max(0, deadline.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.resolveWaiter(id, with: nil)
            }
        }
    }

    private func resolveWaiter(_ id: UUID, with fix: LocationFix?) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: fix)
    }

    private func resolveAllWaiters() {
        let pending = waiters
        waiters.removeAll()
        for (_, waiter) in pending { waiter.continuation.resume(returning: nil) }
    }

    private func deliverToWaiters() {
        for (id, waiter) in waiters {
            if let fix = currentFreshFix(at: waiter.shutter) { resolveWaiter(id, with: fix) }
        }
    }

    // MARK: CLLocationManagerDelegate (delivered on the main run loop where the manager was created)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        MainActor.assumeIsolated {
            self.authorization = status
            self.reducedAccuracy = reduced
            self.reevaluate()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        MainActor.assumeIsolated {
            self.latest = last
            if self.isUpdating { self.phase = .ready }
            self.deliverToWaiters()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated {
            if code == .denied {
                self.authorization = manager.authorizationStatus
                self.reevaluate()
            } else if code != .locationUnknown {
                self.phase = .unavailable
            }
        }
    }
}
