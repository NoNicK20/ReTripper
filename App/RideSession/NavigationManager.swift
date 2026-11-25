//
//  NavigationManager.swift
//  ReTripper
//
//  Navigation state for the ride session. Routing, rerouting, traffic and live
//  guidance come from the Google Navigation SDK; place search comes from Google
//  Places autocomplete. ReTripper keeps the stops, saved/recent places, status
//  and progress, and publishes navigation events for alerts, voice and any
//  future (verified) dashboard output.
//

import Foundation
import CoreLocation
import Combine

enum NavigationEvent: Equatable {
    case started
    case stepAdvanced(RouteProgress)
    case offRoute
    case rerouted
    case arrived(String)
    case failed(String)
    case stopped
}

/// Place search used by the destination screen.
@MainActor
protocol PlaceSearchProvider: AnyObject {
    func suggestions(for query: String, near: CLLocationCoordinate2D?) async throws -> [Destination]
    func finishSession()
}

extension GooglePlacesSearch: PlaceSearchProvider {}

/// Commands sent to the navigation engine (the Google Navigation SDK map).
@MainActor
protocol NavigationEngineControl: AnyObject {
    var isReady: Bool { get }
    var notReadyReason: String { get }
    var onUpdate: ((GoogleNavigationUpdate) -> Void)? { get set }
    func previewRoute(stops: [Destination])
    func startGuidance()
    func stopGuidance()
}

extension GoogleNavigationController: NavigationEngineControl {
    var isReady: Bool { status == .ready && mapView != nil }
    var notReadyReason: String {
        if status == .ready && mapView == nil { return "Open the Map view once so Google Maps can load." }
        return status.summary
    }
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
    static let shared = NavigationManager(engine: GoogleNavigationController.shared, search: GooglePlacesSearch())

    @Published private(set) var status: NavigationStatus = .idle
    @Published private(set) var stops: [Destination] = []
    @Published private(set) var progress: RouteProgress?
    @Published private(set) var lastError: String?

    let events = PassthroughSubject<NavigationEvent, Never>()
    let engineName = "Google Maps Navigation SDK"

    private let engine: NavigationEngineControl
    private let searchProvider: PlaceSearchProvider
    private let store: DestinationStore
    private var initialRemainingMeters: Double?
    private var stepCounter = 0

    init(engine: NavigationEngineControl, search: PlaceSearchProvider, store: DestinationStore = .shared) {
        self.engine = engine
        self.searchProvider = search
        self.store = store
        engine.onUpdate = { [weak self] update in self?.apply(update) }
    }

    var isEngineReady: Bool { engine.isReady }
    var engineNotReadyReason: String { engine.notReadyReason }

    // MARK: Search

    func search(_ query: String, near: CLLocationCoordinate2D?) async -> [Destination] {
        if let shared = DestinationLinkParser.parse(query) { return [shared] }
        do {
            lastError = nil
            return try await searchProvider.suggestions(for: query, near: near)
        } catch {
            lastError = "Google Places search failed: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: Stops

    func setDestination(_ d: Destination) {
        stops = [d]
        store.addRecent(d)
        searchProvider.finishSession()
    }

    func addWaypoint(_ d: Destination) {
        guard stops.count < 8 else { return }
        // Waypoints go before the final destination.
        if stops.isEmpty { stops = [d] } else { stops.insert(d, at: stops.count - 1) }
        store.addRecent(d)
        searchProvider.finishSession()
    }

    func removeStop(at index: Int) {
        guard stops.indices.contains(index) else { return }
        stops.remove(at: index)
        if stops.isEmpty { stopNavigation() }
    }

    // MARK: Routing

    /// Asks Google for routes (with alternatives) and shows them on the map.
    func previewRoute() {
        guard !stops.isEmpty else { return }
        guard engine.isReady else {
            fail(engine.notReadyReason)
            return
        }
        lastError = nil
        status = .calculating
        engine.previewRoute(stops: stops)
    }

    func startGuidance() {
        guard engine.isReady, !stops.isEmpty else {
            fail(engine.notReadyReason)
            return
        }
        switch status {
        case .idle, .failed:
            // Destinations were never sent (Start pressed without a preview, or
            // after a previous failure): send them now. The engine begins
            // guidance once a route exists. Don't resend while `.calculating` —
            // a request is already in flight and resending cancels it (Google
            // reports the first as `.canceled`, status 6).
            engine.previewRoute(stops: stops)
        default:
            break
        }
        engine.startGuidance()
        status = .navigating
        initialRemainingMeters = nil
        stepCounter = 0
        progress = nil
        events.send(.started)
    }

    func stopNavigation() {
        let wasActive = status != .idle
        engine.stopGuidance()
        stops = []
        progress = nil
        status = .idle
        initialRemainingMeters = nil
        if wasActive { events.send(.stopped) }
    }

    private func fail(_ message: String) {
        lastError = message
        status = .failed(message)
        events.send(.failed(message))
    }

    // MARK: Engine updates

    func apply(_ update: GoogleNavigationUpdate) {
        if let failure = update.routeFailed {
            fail(failure)
            return
        }
        if update.routeReady {
            if status == .calculating { status = .preview }
            return
        }
        guard status.isActive || status == .preview else { return }
        if update.arrived {
            status = .arrived
            progress = nil
            events.send(.arrived(stops.last?.name ?? "destination"))
            return
        }
        guard status.isActive else { return }

        let wasRerouting = status == .rerouting
        status = update.isRerouting ? .rerouting : .navigating
        if update.isRerouting && !wasRerouting { events.send(.offRoute) }
        if !update.isRerouting && wasRerouting {
            initialRemainingMeters = nil
            events.send(.rerouted)
        }

        guard let instruction = update.instruction else { return }
        let remaining = max(0, update.remainingMeters ?? 0)
        if initialRemainingMeters == nil, remaining > 0 { initialRemainingMeters = remaining }
        let total = initialRemainingMeters ?? remaining
        let advanced = progress?.nextInstruction != instruction
        if advanced && progress != nil { stepCounter += 1 }

        let p = RouteProgress(
            stepIndex: stepCounter,
            nextManeuver: Maneuver.parse(instruction: instruction),
            nextInstruction: instruction,
            nextRoadName: (update.roadName?.isEmpty ?? true) ? nil : update.roadName,
            distanceToNextManeuverMeters: max(0, update.distanceToStepMeters ?? 0),
            remainingDistanceMeters: remaining,
            remainingSeconds: max(0, update.remainingSeconds ?? 0),
            fractionComplete: total > 0 ? min(1, max(0, 1 - remaining / total)) : 0)
        progress = p
        if advanced { events.send(.stepAdvanced(p)) }
    }
}
