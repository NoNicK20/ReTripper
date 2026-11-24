//
//  GoogleNavigation.swift
//  ReTripper
//
//  Google Maps Navigation SDK integration.
//
//  The SDK is optional at build time. The default build does not include it, so the
//  app always compiles without Google credentials. When the GoogleNavigation Swift
//  package is linked (see project.google.yml) AND an API key is provided through
//  Config/Secrets.xcconfig, ReTripper uses Google's embedded navigation map,
//  routing, rerouting, traffic and voice guidance. Otherwise it falls back to MapKit
//  and says so — MapKit is never presented as Google Maps.
//

import Foundation
import SwiftUI
import CoreLocation
#if canImport(GoogleNavigation)
import GoogleNavigation
#endif

// MARK: - Configuration status

enum GoogleMapsStatus: Equatable {
    case sdkNotLinked
    case missingAPIKey
    case termsNotAccepted
    case ready

    var summary: String {
        switch self {
        case .sdkNotLinked:
            return "Google Navigation SDK is not included in this build. Using Apple Maps (MapKit)."
        case .missingAPIKey:
            return "Google Navigation SDK is included but no API key is configured. Using Apple Maps (MapKit)."
        case .termsNotAccepted:
            return "Google navigation terms have not been accepted on this device yet."
        case .ready:
            return "Google Maps Navigation SDK is ready."
        }
    }
}

enum AppSecretsConfiguration {
    /// Reads a build-time value injected into Info.plist from an untracked xcconfig.
    /// Empty or unexpanded placeholders are treated as missing.
    static func value(forInfoKey key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static var googleMapsAPIKey: String? { value(forInfoKey: "GMSApiKey") }
    static var spotifyClientID: String? { value(forInfoKey: "SpotifyClientID") }
}

@MainActor
final class GoogleNavigationController: ObservableObject {
    static let shared = GoogleNavigationController()

    @Published private(set) var status: GoogleMapsStatus = .sdkNotLinked
    private var apiKeyProvided = false

    static var isSDKLinked: Bool {
        #if canImport(GoogleNavigation)
        return true
        #else
        return false
        #endif
    }

    init() {
        refreshStatus()
    }

    /// Call once at launch. Provides the API key to the SDK when both are available.
    func configureAtLaunch() {
        #if canImport(GoogleNavigation)
        if let key = AppSecretsConfiguration.googleMapsAPIKey, !apiKeyProvided {
            apiKeyProvided = GMSServices.provideAPIKey(key)
        }
        #endif
        refreshStatus()
    }

    func refreshStatus() {
        #if canImport(GoogleNavigation)
        if AppSecretsConfiguration.googleMapsAPIKey == nil {
            status = .missingAPIKey
        } else if !GMSNavigationServices.areTermsAndConditionsAccepted() {
            status = .termsNotAccepted
        } else {
            status = .ready
        }
        #else
        status = .sdkNotLinked
        #endif
    }

    /// Shows Google's required terms dialog. Navigation is unavailable until accepted.
    func requestTermsAcceptance(completion: @escaping (Bool) -> Void) {
        #if canImport(GoogleNavigation)
        GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(withCompanyName: "ReTripper") { [weak self] accepted in
            Task { @MainActor in
                self?.refreshStatus()
                completion(accepted)
            }
        }
        #else
        completion(false)
        #endif
    }
}

// MARK: - Embedded Google navigation map

/// Events forwarded from the Google navigator into ReTripper's ride session.
struct GoogleNavigationUpdate {
    var instruction: String?
    var roadName: String?
    var distanceToStepMeters: Double?
    var remainingMeters: Double?
    var remainingSeconds: TimeInterval?
    var isRerouting: Bool
    var arrived: Bool
    var routeFailed: String?
}

#if canImport(GoogleNavigation)

struct GoogleNavigationMapView: UIViewRepresentable {
    let stops: [Destination]
    let voiceEnabled: Bool
    let onUpdate: (GoogleNavigationUpdate) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUpdate: onUpdate) }

    func makeUIView(context: Context) -> GMSMapView {
        let camera = GMSCameraPosition.camera(withLatitude: 20.59, longitude: 78.96, zoom: 4)
        let mapView = GMSMapView.map(withFrame: .zero, camera: camera)
        mapView.isNavigationEnabled = true
        mapView.isMyLocationEnabled = true
        mapView.isTrafficEnabled = true
        mapView.settings.compassButton = true
        mapView.travelMode = .twoWheeler
        mapView.navigator?.add(context.coordinator)
        context.coordinator.mapView = mapView
        context.coordinator.apply(stops: stops, voiceEnabled: voiceEnabled)
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        context.coordinator.onUpdate = onUpdate
        context.coordinator.apply(stops: stops, voiceEnabled: voiceEnabled)
    }

    static func dismantleUIView(_ mapView: GMSMapView, coordinator: Coordinator) {
        mapView.navigator?.isGuidanceActive = false
        mapView.navigator?.clearDestinations()
        _ = mapView.navigator?.remove(coordinator)
    }

    final class Coordinator: NSObject, GMSNavigatorListener {
        var onUpdate: (GoogleNavigationUpdate) -> Void
        weak var mapView: GMSMapView?
        private var appliedStops: [Destination] = []

        init(onUpdate: @escaping (GoogleNavigationUpdate) -> Void) {
            self.onUpdate = onUpdate
        }

        func apply(stops: [Destination], voiceEnabled: Bool) {
            guard let mapView, let navigator = mapView.navigator else { return }
            navigator.voiceGuidance = voiceEnabled ? .alertsAndGuidance : .silent
            guard stops != appliedStops else { return }
            appliedStops = stops
            guard !stops.isEmpty else {
                navigator.clearDestinations()
                return
            }
            let waypoints = stops.compactMap {
                GMSNavigationWaypoint(location: $0.coordinate, title: $0.name)
            }
            navigator.setDestinations(waypoints) { [weak self] routeStatus in
                guard let self else { return }
                if routeStatus == .OK {
                    navigator.isGuidanceActive = true
                    mapView.cameraMode = .following
                } else {
                    self.onUpdate(GoogleNavigationUpdate(isRerouting: false, arrived: false,
                                                         routeFailed: "Google could not calculate a route (status \(routeStatus.rawValue))."))
                }
            }
        }

        func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
            let step = navInfo.currentStep
            onUpdate(GoogleNavigationUpdate(
                instruction: step?.fullInstructionText,
                roadName: step?.fullRoadName,
                distanceToStepMeters: navInfo.distanceToCurrentStepMeters,
                remainingMeters: navInfo.distanceToFinalDestinationMeters,
                remainingSeconds: navInfo.timeToFinalDestinationSeconds,
                isRerouting: navInfo.navState == .rerouting,
                arrived: false,
                routeFailed: nil))
        }

        func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
            onUpdate(GoogleNavigationUpdate(isRerouting: false, arrived: true, routeFailed: nil))
        }
    }
}

#endif
