import CoreLocation
import Foundation
import Observation

/// CLLocationManager wrapper for the weather widget's "current location"
/// mode. City-level accuracy is plenty; the fix is refreshed when older than
/// 15 minutes. Denied/failed states surface to the widget, which points the
/// user at the manual city picker.
@MainActor @Observable public final class LocationProvider: NSObject {
    public enum State: Equatable, Sendable {
        case idle
        case waitingForPermission
        case locating
        case located(latitude: Double, longitude: Double)
        case denied
        case failed
    }

    public private(set) var state: State = .idle
    /// Reverse-geocoded locality ("Shibuya"); nil until resolved.
    public private(set) var placeLabel: String?

    private let manager = CLLocationManager()
    private var lastFix = Date.distantPast
    private let refreshInterval: TimeInterval = 900

    override public init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Idempotent kick from the widget's poll loop: asks for permission the
    /// first time, then re-requests a fix when the current one goes stale.
    public func requestIfNeeded(now: Date = Date()) {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Ask exactly once per launch — the poll loop lands here every
            // few seconds and re-requesting while the consent prompt is
            // pending can keep it from ever appearing.
            guard state != .waitingForPermission else { return }
            state = .waitingForPermission
            manager.requestWhenInUseAuthorization()
            // Queue a one-shot fix too: an actual location request raises
            // the consent prompt more reliably for agent (LSUIElement)
            // apps, and delivers the fix right after a grant.
            manager.requestLocation()
        case .denied, .restricted:
            state = .denied
        case .authorizedAlways: // the only granted status on macOS
            if case .locating = state { return }
            guard now.timeIntervalSince(lastFix) > refreshInterval else { return }
            if case .located = state {} else { state = .locating }
            manager.requestLocation()
        default:
            state = .failed
        }
    }

    private func handleFix(latitude: Double, longitude: Double) {
        lastFix = Date()
        state = .located(latitude: latitude, longitude: longitude)
        Task { [weak self] in
            // CLGeocoder is deprecated on macOS 26 in favor of MapKit's
            // MKReverseGeocodingRequest, but that has no macOS 15 fallback —
            // and this only feeds a cosmetic label.
            let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude)
            )
            let placemark = placemarks?.first
            self?.placeLabel = placemark?.locality ?? placemark?.administrativeArea
        }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    // Delegate callbacks land on the thread that created the manager (main
    // here), but the protocol is nonisolated in Swift 6 — hop explicitly.
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.requestIfNeeded() }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let (latitude, longitude) = (coordinate.latitude, coordinate.longitude)
        Task { @MainActor [weak self] in self?.handleFix(latitude: latitude, longitude: longitude) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The implicit request made while consent is pending fails with
            // kCLErrorDenied before the user has actually answered — stay in
            // waitingForPermission; a real denial arrives via
            // locationManagerDidChangeAuthorization. Keep an existing fix
            // through transient errors.
            guard case .locating = self.state else { return }
            self.state = .failed
        }
    }
}
