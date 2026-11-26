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

    /// Last routing outcome in plain words (for the on-screen diagnostic).
    /// Records every outcome, including the ones not surfaced as errors, so the
    /// exact Google route status is visible while we confirm routing behaviour.
    @Published private(set) var lastRouteDiagnostic: String?

    /// Receives navigator updates (set by NavigationManager).
    var onUpdate: ((GoogleNavigationUpdate) -> Void)?

    private(set) var mapView: GMSMapView?
    private var servicesConfigured = false
    private var appliedStops: [Destination] = []
    private var suggestedLowLight = false

    /// Self-serve routing (Routes API). ReTripper draws the route itself; the
    /// gated Navigation SDK is no longer used to compute or render routes.
    private let routes = RoutesAPIClient()
    private var routePolylines: [GMSPolyline] = []
    private(set) var lastRouteInfo: RouteResult?

    /// Live turn-by-turn, built on the Routes API route + the rider's GPS.
    private let guidanceLocation = CLLocationManager()
    private var tracker: RouteTracker?
    private var guiding = false
    private var rerouting = false
    private var offRouteStreak = 0
    private static let offRouteMeters: CLLocationDistance = 45

    /// A route the rider asked for before a GPS fix was available. We start
    /// location updates, then compute the route as soon as the first fix lands.
    private var pendingPreviewStops: [Destination]?

    override init() {
        super.init()
        guidanceLocation.delegate = self
        guidanceLocation.desiredAccuracy = kCLLocationAccuracyBestForNavigation
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

    /// Computes a route through all stops (via the self-serve Routes API) and
    /// draws it on the map. ReTripper draws the line itself with GMSPolyline;
    /// the gated Navigation SDK is no longer used for routing.
    func previewRoute(stops: [Destination]) {
        guard let mapView else {
            lastRouteDiagnostic = "Map not ready yet."
            onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false,
                                             routeFailed: "Google Maps isn't ready. \(status.summary)"))
            return
        }
        guard let origin = resolveOrigin() else {
            // No fix yet. Instead of failing, remember the request, turn on
            // location, and compute the route the moment the first fix arrives.
            pendingPreviewStops = stops
            lastRouteDiagnostic = "Getting your location (GPS)… this can take a few seconds."
            guidanceLocation.requestWhenInUseAuthorization()
            guidanceLocation.startUpdatingLocation()
            return
        }
        guard let last = stops.last else { return }
        appliedStops = stops
        lastRouteDiagnostic = "Requesting route via Routes API… (\(stops.count) stop(s))"
        let destination = RoutesAPIClient.Waypoint(coordinate: last.coordinate, placeID: last.placeID)
        let intermediates = stops.dropLast().map {
            RoutesAPIClient.Waypoint(coordinate: $0.coordinate, placeID: $0.placeID)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.computeWithFallback(origin: origin, destination: destination,
                                                                intermediates: Array(intermediates))
                self.applyRoute(result)
            } catch {
                self.applyRouteFailure(error)
            }
        }
    }

    /// The rider's current position, from the map's own location or, if the map
    /// hasn't reported one yet, the device location manager's last fix.
    private func resolveOrigin() -> CLLocationCoordinate2D? {
        if let c = mapView?.myLocation?.coordinate { return c }
        if let c = guidanceLocation.location?.coordinate, CLLocationCoordinate2DIsValid(c) { return c }
        return nil
    }

    /// Prefer a two-wheeler route (apt for the motorcycle, and offered in Royal
    /// Enfield's core markets); fall back to driving where two-wheeler routing
    /// isn't available. An auth error (403) is not retried.
    private func computeWithFallback(origin: CLLocationCoordinate2D,
                                     destination: RoutesAPIClient.Waypoint,
                                     intermediates: [RoutesAPIClient.Waypoint]) async throws -> RouteResult {
        do {
            return try await routes.compute(origin: origin, destination: destination,
                                            intermediates: intermediates, mode: .twoWheeler)
        } catch RoutesAPIError.noRoute {
            return try await routes.compute(origin: origin, destination: destination,
                                            intermediates: intermediates, mode: .drive)
        } catch let RoutesAPIError.http(code, _) where code == 400 {
            return try await routes.compute(origin: origin, destination: destination,
                                            intermediates: intermediates, mode: .drive)
        }
    }

    private func applyRoute(_ result: RouteResult) {
        lastRouteInfo = result
        drawRoute(result.encodedPolyline, frame: !guiding)
        // Share the route geometry with the dash map renderer so it draws the
        // same line on the bike's screen.
        DashRouteStore.shared.setRoute(EncodedPolyline.decode(result.encodedPolyline))
        if guiding { tracker = RouteTracker(route: result) }
        let km = result.distanceMeters / 1000
        let minutes = Int((result.durationSeconds / 60).rounded())
        lastRouteDiagnostic = String(format: "Route OK — %.1f km, ~%d min (Routes API)", km, minutes)
        onUpdate?(GoogleNavigationUpdate(remainingMeters: result.distanceMeters,
                                         remainingSeconds: result.durationSeconds,
                                         isRerouting: false, arrived: false, routeReady: true))
    }

    private func applyRouteFailure(_ error: Error) {
        let friendly = (error as? RoutesAPIError)?.errorDescription
            ?? "Couldn't get a route: \(error.localizedDescription)"
        lastRouteDiagnostic = "Route failed — \(friendly)"
        onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false, routeFailed: friendly))
    }

    /// Draws the route line on the map. When `frame` is true (preview) it fits
    /// the whole route in view; during guidance the camera keeps following the
    /// rider, so framing is skipped.
    private func drawRoute(_ encoded: String, frame: Bool = true) {
        clearRoute()
        guard let mapView, let path = GMSPath(fromEncodedPath: encoded) else { return }
        let line = GMSPolyline(path: path)
        line.strokeWidth = 7
        line.strokeColor = UIColor.systemBlue
        line.zIndex = 5
        line.map = mapView
        routePolylines = [line]
        if frame {
            mapView.cameraMode = .free
            let bounds = GMSCoordinateBounds(path: path)
            mapView.animate(with: GMSCameraUpdate.fit(bounds, withPadding: 56))
        }
    }

    private func clearRoute() {
        routePolylines.forEach { $0.map = nil }
        routePolylines = []
    }

    func startGuidance() {
        // Live turn-by-turn from the Routes API route + the rider's GPS.
        guiding = true
        offRouteStreak = 0
        rerouting = false
        if let info = lastRouteInfo { tracker = RouteTracker(route: info) }
        guidanceLocation.requestWhenInUseAuthorization()
        guidanceLocation.startUpdatingLocation()
        mapView?.cameraMode = .free
    }

    func stopGuidance() {
        guiding = false
        rerouting = false
        offRouteStreak = 0
        guidanceLocation.stopUpdatingLocation()
        tracker = nil
        clearRoute()
        DashRouteStore.shared.clear()
        lastRouteInfo = nil
        lastRouteDiagnostic = nil
        appliedStops = []
        mapView?.cameraMode = .following
    }

    /// Called ~1 Hz with the rider's position while guiding. Emits the same
    /// update shape the UI already consumes, and triggers a reroute when the
    /// rider drifts off the line.
    /// First stop for every GPS fix: fulfil a route the rider asked for before a
    /// fix was available, then feed live guidance (a no-op when not guiding).
    private func onLocationFix(_ coord: CLLocationCoordinate2D, course: CLLocationDirection) {
        if let stops = pendingPreviewStops {
            pendingPreviewStops = nil
            if !guiding { guidanceLocation.stopUpdatingLocation() }
            previewRoute(stops: stops)
        }
        handleGuidanceLocation(coord, course: course)
    }

    private func handleGuidanceLocation(_ coord: CLLocationCoordinate2D, course: CLLocationDirection) {
        guard guiding else { return }
        let bearing = course >= 0 ? course : 0
        mapView?.animate(to: GMSCameraPosition(target: coord, zoom: 17, bearing: bearing, viewingAngle: 45))
        guard let tracker else { return }
        let snap = tracker.snapshot(for: coord)
        if snap.arrived {
            DashRouteStore.shared.clear()
            onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: true))
            return
        }
        // Feed the next turn to the dash map's turn banner.
        DashRouteStore.shared.setManeuver(snap.maneuver, distance: snap.distanceToManeuver)
        if snap.lateralOffset > Self.offRouteMeters {
            offRouteStreak += 1
            if offRouteStreak >= 3 && !rerouting { reroute(from: coord) }
        } else {
            offRouteStreak = 0
        }
        onUpdate?(GoogleNavigationUpdate(
            instruction: snap.instruction.isEmpty ? "Continue" : snap.instruction,
            roadName: nil,
            distanceToStepMeters: snap.distanceToManeuver,
            remainingMeters: snap.remainingDistance,
            remainingSeconds: snap.remainingDuration,
            isRerouting: rerouting,
            arrived: false))
    }

    /// Recomputes the route from the rider's current position to the final
    /// destination when they've gone off route.
    private func reroute(from coord: CLLocationCoordinate2D) {
        guard let last = appliedStops.last else { return }
        rerouting = true
        offRouteStreak = 0
        lastRouteDiagnostic = "Off route — recalculating…"
        let destination = RoutesAPIClient.Waypoint(coordinate: last.coordinate, placeID: last.placeID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.computeWithFallback(origin: coord, destination: destination,
                                                                intermediates: [])
                self.lastRouteInfo = result
                self.drawRoute(result.encodedPolyline, frame: false)
                self.tracker = RouteTracker(route: result)
                self.rerouting = false
                self.lastRouteDiagnostic = "Rerouted."
            } catch {
                self.rerouting = false
                self.offRouteStreak = 0
            }
        }
    }

    func recenter() {
        mapView?.cameraMode = .following
    }

    /// Step the map zoom (driven by the bike's control stick when the map is
    /// shown on the dash). Clamped to a sensible range.
    func zoomIn() { stepZoom(by: 1) }
    func zoomOut() { stepZoom(by: -1) }

    private func stepZoom(by delta: Float) {
        guard let mapView else { return }
        let target = max(3, min(20, mapView.camera.zoom + delta))
        mapView.animate(toZoom: target)
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

extension GoogleNavigationController: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coord = loc.coordinate
        let course = loc.course
        Task { @MainActor in self.onLocationFix(coord, course: course) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.pendingPreviewStops != nil else { return }
            self.pendingPreviewStops = nil
            self.lastRouteDiagnostic = "Couldn't get your location (GPS). Go outdoors or check location access, then try again."
            self.onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false,
                routeFailed: "Couldn't get your GPS position. Make sure location access is allowed and you have a clear view of the sky, then try again."))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.pendingPreviewStops != nil else { return }
            if status == .denied || status == .restricted {
                self.pendingPreviewStops = nil
                self.lastRouteDiagnostic = "Location access is off, so routing can't start."
                self.onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false,
                    routeFailed: "ReTripper needs location access to route from where you are. Turn it on in Settings, then try again."))
            }
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
