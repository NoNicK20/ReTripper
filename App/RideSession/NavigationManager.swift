//
//  NavigationManager.swift
//  ReTripper
//
//  Coordinates destination search, route calculation, route alternatives,
//  waypoints, live progress, deviation detection and automatic rerouting.
//

import Foundation
import CoreLocation
import Combine

enum NavigationEvent: Equatable {
    case started
    case stepAdvanced(RouteProgress)
    case offRoute
    case rerouted
    case rerouteFailed(String)
    case arrived(String)
    case stopped
}

@MainActor
final class DestinationStore: ObservableObject {
    static let shared = DestinationStore()

    @Published private(set) var saved: [Destination] = []
    @Published private(set) var recent: [Destination] = []

    private let defaults: UserDefaults
    private let savedKey = "retripper_saved_destinations"
    private let recentKey = "retripper_recent_destinations"
    private let maxRecent = 15

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = load(savedKey)
        recent = load(recentKey)
    }

    func isSaved(_ d: Destination) -> Bool { saved.contains { $0.isSamePlace(as: d) } }

    func toggleSaved(_ d: Destination) {
        if isSaved(d) {
            saved.removeAll { $0.isSamePlace(as: d) }
        } else {
            saved.insert(d, at: 0)
        }
        store(saved, savedKey)
    }

    func addRecent(_ d: Destination) {
        recent.removeAll { $0.isSamePlace(as: d) }
        recent.insert(d, at: 0)
        if recent.count > maxRecent { recent = Array(recent.prefix(maxRecent)) }
        store(recent, recentKey)
    }

    func clearRecent() {
        recent = []
        store(recent, recentKey)
    }

    private func load(_ key: String) -> [Destination] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Destination].self, from: data)) ?? []
    }

    private func store(_ list: [Destination], _ key: String) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}

@MainActor
final class NavigationManager: ObservableObject {
    static let shared = NavigationManager()

    @Published private(set) var status: NavigationStatus = .idle
    @Published var stops: [Destination] = []
    @Published private(set) var candidateRoutes: [NavRoute] = []
    @Published var selectedRouteIndex: Int = 0
    @Published private(set) var activeRoute: NavRoute?
    @Published private(set) var progress: RouteProgress?
    @Published private(set) var engine: NavigationEngine = .appleMapKit
    @Published private(set) var lastError: String?

    let events = PassthroughSubject<NavigationEvent, Never>()

    private let provider: NavigationRouteProvider
    private var tracker: RouteProgressTracker?
    private var lastRerouteAt: Date?
    private var lastAnnouncedStep: Int = -1
    private let minimumRerouteInterval: TimeInterval = 15

    init(provider: NavigationRouteProvider = MapKitRouteProvider()) {
        self.provider = provider
    }

    var selectedRoute: NavRoute? {
        candidateRoutes.indices.contains(selectedRouteIndex) ? candidateRoutes[selectedRouteIndex] : nil
    }

    // MARK: Search

    func search(_ query: String, near: CLLocationCoordinate2D?) async -> [Destination] {
        if let shared = DestinationLinkParser.parse(query) { return [shared] }
        do {
            lastError = nil
            return try await provider.searchDestinations(query: query, near: near)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    // MARK: Stops

    func setDestination(_ d: Destination) {
        stops = [d]
        DestinationStore.shared.addRecent(d)
    }

    func addWaypoint(_ d: Destination) {
        guard stops.count < 8 else { return }
        // Waypoints go before the final destination.
        if stops.isEmpty { stops = [d] } else { stops.insert(d, at: stops.count - 1) }
        DestinationStore.shared.addRecent(d)
    }

    func removeStop(at index: Int) {
        guard stops.indices.contains(index) else { return }
        stops.remove(at: index)
    }

    // MARK: Routing (MapKit engine)

    func calculateRoutes(from origin: CLLocationCoordinate2D) async {
        guard !stops.isEmpty else { return }
        engine = .appleMapKit
        status = .calculating
        lastError = nil
        do {
            candidateRoutes = try await provider.calculateRoutes(from: origin, stops: stops)
            selectedRouteIndex = 0
            status = .preview
        } catch {
            candidateRoutes = []
            lastError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    func startGuidance() {
        guard let route = selectedRoute else { return }
        activate(route)
        events.send(.started)
    }

    private func activate(_ route: NavRoute) {
        activeRoute = route
        tracker = RouteProgressTracker(route: route)
        progress = nil
        lastAnnouncedStep = -1
        status = .navigating
    }

    func stopNavigation() {
        let wasActive = status.isActive || engine == .googleNavigationSDK
        activeRoute = nil
        tracker = nil
        progress = nil
        candidateRoutes = []
        stops = []
        status = .idle
        engine = .appleMapKit
        if wasActive { events.send(.stopped) }
    }

    /// Feed live locations while navigating with the MapKit engine.
    func update(location: CLLocation) {
        guard engine == .appleMapKit, status.isActive, var tracker = tracker else { return }
        let outcome = tracker.update(with: location.coordinate, accuracy: location.horizontalAccuracy)
        self.tracker = tracker
        switch outcome {
        case .onRoute(let p):
            progress = p
            if status == .rerouting { status = .navigating }
            if p.stepIndex != lastAnnouncedStep {
                lastAnnouncedStep = p.stepIndex
                events.send(.stepAdvanced(p))
            }
        case .offRoute:
            events.send(.offRoute)
            reroute(from: location)
        case .arrived:
            let name = activeRoute?.stops.last?.name ?? "destination"
            status = .arrived
            progress = nil
            events.send(.arrived(name))
        case .noGeometry:
            break
        }
    }

    private func reroute(from location: CLLocation) {
        if let last = lastRerouteAt, Date().timeIntervalSince(last) < minimumRerouteInterval { return }
        guard let route = activeRoute else { return }
        lastRerouteAt = Date()
        status = .rerouting
        let remainingStops = route.stops
        Task {
            do {
                let routes = try await provider.calculateRoutes(from: location.coordinate, stops: remainingStops)
                guard self.status == .rerouting, let best = routes.first else { return }
                self.activate(best)
                self.events.send(.rerouted)
            } catch {
                self.lastError = error.localizedDescription
                self.status = .navigating   // keep guiding on the old route
                self.events.send(.rerouteFailed(error.localizedDescription))
            }
        }
    }

    // MARK: Google engine bridge

    /// Starts guidance driven by the embedded Google Navigation SDK map.
    func startGoogleGuidance() {
        guard !stops.isEmpty else { return }
        engine = .googleNavigationSDK
        activeRoute = nil
        tracker = nil
        status = .navigating
        events.send(.started)
    }

    func applyGoogleUpdate(_ update: GoogleNavigationUpdate) {
        guard engine == .googleNavigationSDK else { return }
        if let failure = update.routeFailed {
            status = .failed(failure)
            lastError = failure
            return
        }
        if update.arrived {
            status = .arrived
            progress = nil
            events.send(.arrived(stops.last?.name ?? "destination"))
            return
        }
        let wasRerouting = status == .rerouting
        status = update.isRerouting ? .rerouting : .navigating
        if update.isRerouting && !wasRerouting { events.send(.offRoute) }
        guard let instruction = update.instruction else { return }
        let p = RouteProgress(
            stepIndex: progress.map { $0.nextInstruction == instruction ? $0.stepIndex : $0.stepIndex + 1 } ?? 0,
            nextManeuver: Maneuver.parse(instruction: instruction),
            nextInstruction: instruction,
            nextRoadName: update.roadName,
            distanceToNextManeuverMeters: update.distanceToStepMeters ?? 0,
            remainingDistanceMeters: update.remainingMeters ?? 0,
            remainingSeconds: update.remainingSeconds ?? 0,
            fractionComplete: 0,
            distanceFromRouteMeters: 0)
        let advanced = progress?.nextInstruction != instruction
        progress = p
        if advanced { events.send(.stepAdvanced(p)) }
    }
}
