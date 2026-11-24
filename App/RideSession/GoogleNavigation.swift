//
//  GoogleNavigation.swift
//  ReTripper
//
//  Embedded Google Maps + Google Navigation SDK. Google Maps is ReTripper's
//  primary and only map engine: the real GMSMapView is rendered natively inside
//  the app (no Google Maps app launch, no Safari, no WebView, no Apple Maps fallback).
//
//  The API key is injected at build time (Config/Secrets.xcconfig locally, or the
//  GOOGLE_MAPS_API_KEY GitHub Actions secret) into Info.plist as GMSApiKey.
//  Without a key the app shows a configuration message instead of a map.
//

import Foundation
import SwiftUI
import UIKit
import CoreLocation
import GoogleNavigation
import GooglePlaces

// MARK: - Configuration status

enum GoogleMapsStatus: Equatable {
    case missingAPIKey
    case termsNotAccepted
    case ready

    var summary: String {
        switch self {
        case .missingAPIKey:
            return "Google Maps is not configured: this build has no Google Maps API key. Add one (see GOOGLE_MAPS_SETUP.md) and rebuild."
        case .termsNotAccepted:
            return "Accept Google's navigation terms to use Google Maps navigation."
        case .ready:
            return "Google Maps and Google Navigation are ready."
        }
    }
}

enum AppSecretsConfiguration {
    /// Reads a build-time value injected into Info.plist. Empty or unexpanded placeholders count as missing.
    static func value(forInfoKey key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static var googleMapsAPIKey: String? { value(forInfoKey: "GMSApiKey") }
    static var spotifyClientID: String? { value(forInfoKey: "SpotifyClientID") }
}

/// Map appearance chosen by the rider.
enum MapLighting: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case day = "Day"
    case night = "Night"
    var id: String { rawValue }
}

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
    var routeReady: Bool = false
}

// MARK: - Controller (owns the single GMSMapView)

@MainActor
final class GoogleNavigationController: NSObject, ObservableObject {
    static let shared = GoogleNavigationController()

    @Published private(set) var status: GoogleMapsStatus = .missingAPIKey
    @Published var lighting: MapLighting = .auto { didSet { applyLighting() } }
    @Published var showsTraffic = true { didSet { mapView?.isTrafficEnabled = showsTraffic } }

    /// Receives navigator updates (set by NavigationManager).
    var onUpdate: ((GoogleNavigationUpdate) -> Void)?

    private(set) var mapView: GMSMapView?
    private var servicesConfigured = false
    private var appliedStops: [Destination] = []
    private var suggestedLowLight = false

    override init() {
        super.init()
        refreshStatus()
    }

    // MARK: Setup

    /// Provides the API key to the Maps, Navigation and Places SDKs. Call once at launch.
    func configureAtLaunch() {
        guard !servicesConfigured, let key = AppSecretsConfiguration.googleMapsAPIKey else {
            refreshStatus()
            return
        }
        servicesConfigured = GMSServices.provideAPIKey(key)
        _ = GMSPlacesClient.provideAPIKey(key)
        refreshStatus()
    }

    func refreshStatus() {
        if AppSecretsConfiguration.googleMapsAPIKey == nil || !servicesConfigured {
            status = .missingAPIKey
        } else if !GMSNavigationServices.areTermsAndConditionsAccepted() {
            status = .termsNotAccepted
        } else {
            status = .ready
        }
    }

    /// Shows Google's required navigation terms dialog.
    func requestTermsAcceptance(completion: @escaping (Bool) -> Void = { _ in }) {
        guard servicesConfigured else { completion(false); return }
        GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(withCompanyName: "ReTripper") { [weak self] accepted in
            Task { @MainActor in
                self?.refreshStatus()
                if accepted { self?.enableNavigationIfPossible() }
                completion(accepted)
            }
        }
    }

    /// Returns the shared map view, creating it on first use. Only valid once the key is configured.
    func makeOrReuseMapView() -> GMSMapView? {
        guard servicesConfigured else { return nil }
        if let mapView { return mapView }
        let camera = GMSCameraPosition.camera(withLatitude: 20.59, longitude: 78.96, zoom: 4)
        let view = GMSMapView.map(withFrame: .zero, camera: camera)
        view.isMyLocationEnabled = true
        view.isTrafficEnabled = showsTraffic
        view.settings.compassButton = true
        view.settings.myLocationButton = true
        view.settings.isRecenterButtonEnabled = true
        // ReTripper draws its own direction card and trip/ETA strip; Google's logo and
        // map controls stay visible (map padding keeps them clear of the overlays).
        view.settings.isNavigationHeaderEnabled = false
        view.settings.isNavigationFooterEnabled = false
        mapView = view
        enableNavigationIfPossible()
        applyLighting()
        return view
    }

    private func enableNavigationIfPossible() {
        guard let mapView, status == .ready, !mapView.isNavigationEnabled else { return }
        mapView.isNavigationEnabled = true
        mapView.travelMode = .twoWheeler
        mapView.navigator?.add(self)
        mapView.cameraMode = .following
    }

    // MARK: Commands

    /// Keeps Google's logo and buttons clear of ReTripper's overlays.
    func setPadding(_ insets: UIEdgeInsets) {
        guard let mapView, mapView.padding != insets else { return }
        mapView.padding = insets
    }

    /// Requests routes (with alternatives) through all stops and shows them on the map.
    func previewRoute(stops: [Destination]) {
        guard let navigator = mapView?.navigator else {
            onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false,
                                             routeFailed: "Google navigation is not ready. \(status.summary)"))
            return
        }
        appliedStops = stops
        let waypoints = stops.compactMap { stop -> GMSNavigationWaypoint? in
            if let placeID = stop.placeID {
                return GMSNavigationWaypoint(placeID: placeID, title: stop.name)
            }
            return GMSNavigationWaypoint(location: stop.coordinate, title: stop.name)
        }
        guard !waypoints.isEmpty else { return }
        let options = GMSNavigationRoutingOptions(alternateRoutesStrategy: .all)
        navigator.setDestinations(waypoints, routingOptions: options) { [weak self] routeStatus in
            guard let self else { return }
            if routeStatus == .OK {
                if self.mapView?.navigator?.isGuidanceActive != true {
                    self.mapView?.cameraMode = .overview
                }
                self.onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false, routeFailed: nil, routeReady: true))
            } else {
                self.onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false,
                                                      routeFailed: "Google could not calculate a route (status \(routeStatus.rawValue))."))
            }
        }
    }

    func startGuidance() {
        guard let mapView, let navigator = mapView.navigator else { return }
        navigator.isGuidanceActive = true
        mapView.cameraMode = .following
    }

    func stopGuidance() {
        guard let navigator = mapView?.navigator else { return }
        navigator.isGuidanceActive = false
        navigator.clearDestinations()
        appliedStops = []
        mapView?.cameraMode = .following
    }

    func recenter() {
        mapView?.cameraMode = .following
    }

    /// Maps ReTripper's guidance mode onto Google's own voice guidance.
    func setVoice(_ mode: GuidanceMode, callActive: Bool) {
        guard let navigator = mapView?.navigator else { return }
        if callActive {
            navigator.voiceGuidance = .silent
            return
        }
        switch mode {
        case .full: navigator.voiceGuidance = .alertsAndGuidance
        case .importantOnly: navigator.voiceGuidance = .alertsOnly
        case .muted: navigator.voiceGuidance = .silent
        }
    }

    private func applyLighting() {
        guard let mapView else { return }
        switch lighting {
        case .day: mapView.lightingMode = .normal
        case .night: mapView.lightingMode = .lowLight
        case .auto: mapView.lightingMode = suggestedLowLight ? .lowLight : .normal
        }
    }
}

extension GoogleNavigationController: GMSNavigatorListener {
    nonisolated func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
        let step = navInfo.currentStep
        let update = GoogleNavigationUpdate(
            instruction: step?.fullInstructionText,
            roadName: step?.fullRoadName,
            distanceToStepMeters: navInfo.distanceToCurrentStepMeters,
            remainingMeters: navInfo.distanceToFinalDestinationMeters,
            remainingSeconds: navInfo.timeToFinalDestinationSeconds,
            isRerouting: navInfo.navState == .rerouting,
            arrived: false,
            routeFailed: nil)
        Task { @MainActor in self.onUpdate?(update) }
    }

    nonisolated func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
        Task { @MainActor in
            self.onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: true, routeFailed: nil))
        }
    }

    nonisolated func navigator(_ navigator: GMSNavigator, didChangeSuggestedLightingMode lightingMode: GMSNavigationLightingMode) {
        let lowLight = lightingMode == .lowLight
        Task { @MainActor in
            self.suggestedLowLight = lowLight
            self.applyLighting()
        }
    }
}

// MARK: - SwiftUI host for the real GMSMapView

struct GoogleMapHostView: UIViewRepresentable {
    @ObservedObject var controller: GoogleNavigationController
    let padding: UIEdgeInsets

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        if let map = controller.makeOrReuseMapView() {
            map.removeFromSuperview()
            map.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(map)
            NSLayoutConstraint.activate([
                map.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                map.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                map.topAnchor.constraint(equalTo: container.topAnchor),
                map.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.setPadding(padding)
    }
}

// MARK: - Google Places search (Places API (New) autocomplete)

@MainActor
final class GooglePlacesSearch {
    private var sessionToken = GMSAutocompleteSessionToken()

    /// Autocomplete suggestions biased to the rider's location. Results carry a Place ID,
    /// which the Navigation SDK routes to directly (no extra Place Details request).
    func suggestions(for query: String, near: CLLocationCoordinate2D?) async throws -> [Destination] {
        let cleaned = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !cleaned.isEmpty else { return [] }
        let request = GMSAutocompleteRequest(query: cleaned)
        request.sessionToken = sessionToken
        if let near {
            let filter = GMSAutocompleteFilter()
            filter.origin = CLLocation(latitude: near.latitude, longitude: near.longitude)
            filter.locationBias = GMSPlaceCircularLocationOption(near, 50_000)
            request.filter = filter
        }
        return try await withCheckedThrowingContinuation { continuation in
            GMSPlacesClient.shared().fetchAutocompleteSuggestions(from: request, callback: { results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let destinations: [Destination] = (results ?? []).compactMap { suggestion in
                    guard let place = suggestion.placeSuggestion else { return nil }
                    return Destination(name: place.attributedPrimaryText.string,
                                       subtitle: place.attributedSecondaryText?.string ?? "",
                                       latitude: 0, longitude: 0,
                                       placeID: place.placeID)
                }
                continuation.resume(returning: destinations)
            })
        }
    }

    /// Ends the billing session once the rider has picked a destination.
    func finishSession() {
        sessionToken = GMSAutocompleteSessionToken()
    }
}
