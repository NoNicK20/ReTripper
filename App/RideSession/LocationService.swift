//
//  LocationService.swift
//  ReTripper
//
//  The single CLLocationManager used by the ride session. Subsystems register
//  as named clients; updates run only while at least one client needs them,
//  which prevents duplicate location managers and wasted battery.
//

import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    enum Client: String { case rideRecording, navigation, rideScreen, compass }

    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var latestHeading: CLHeading?
    @Published private(set) var lastError: String?

    /// Emits every raw location delivered by CoreLocation.
    let locationUpdates = PassthroughSubject<CLLocation, Never>()

    private let manager = CLLocationManager()
    private var locationClients = Set<Client>()
    private var headingClients = Set<Client>()

    var headingAvailable: Bool { CLLocationManager.headingAvailable() }

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 1
    }

    func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func startLocation(for client: Client) {
        requestAuthorizationIfNeeded()
        let wasEmpty = locationClients.isEmpty
        locationClients.insert(client)
        configureBackgroundUpdates()
        if wasEmpty { manager.startUpdatingLocation() }
    }

    func stopLocation(for client: Client) {
        locationClients.remove(client)
        configureBackgroundUpdates()
        if locationClients.isEmpty { manager.stopUpdatingLocation() }
    }

    func startHeading(for client: Client) {
        guard CLLocationManager.headingAvailable() else { return }
        let wasEmpty = headingClients.isEmpty
        headingClients.insert(client)
        if wasEmpty { manager.startUpdatingHeading() }
    }

    func stopHeading(for client: Client) {
        headingClients.remove(client)
        if headingClients.isEmpty { manager.stopUpdatingHeading() }
    }

    /// Background updates are only enabled while a ride is being recorded or navigation is active.
    private func configureBackgroundUpdates() {
        let needsBackground = locationClients.contains(.rideRecording) || locationClients.contains(.navigation)
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        let allowed = needsBackground && modes.contains("location")
        manager.allowsBackgroundLocationUpdates = allowed
        manager.showsBackgroundLocationIndicator = allowed
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                self.latestLocation = location
                self.locationUpdates.send(location)
            }
            self.lastError = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.latestHeading = newHeading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
