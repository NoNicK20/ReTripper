//
//  RideSessionManager.swift
//  ReTripper
//
//  Unified ride session. Owns the wiring between the single location service,
//  trip meter, compass, navigation, voice guidance, call alerts, music,
//  contextual alerts and dashboard connection state. Uses one 1 Hz timer that
//  runs only while a ride or navigation is active.
//

import Foundation
import CoreLocation
import Combine
import UIKit

@MainActor
final class RideSessionManager: ObservableObject {
    static let shared = RideSessionManager()

    @Published private(set) var rideState: RideState = .idle
    @Published private(set) var rideStartedAt: Date?
    @Published private(set) var recoveredFromInterruption = false
    @Published private(set) var lastSavedRide: RideLog?

    let location: LocationService
    let tripMeter: TripMeterManager
    let compass: CompassManager
    let navigation: NavigationManager
    let audio: NavigationAudioManager
    let calls: CallAlertManager
    let music: MusicManager
    let alerts: ContextualAlertManager
    let dashboard: DashboardConnectionManager
    let google: GoogleNavigationController

    private var cancellables = Set<AnyCancellable>()
    private var ticker: AnyCancellable?
    private var screenVisible = false
    private var lastReminderCheck: Date?
    /// True while the current ride was started automatically by connecting to
    /// the bike, so we only auto-end rides we auto-started (never a manual one).
    private var rideWasAutoStarted = false

    /// What the bike's control stick currently drives. Click toggles it.
    enum DashStickMode { case map, music }
    @Published private(set) var stickMode: DashStickMode = .map

    init(location: LocationService = .shared,
         tripMeter: TripMeterManager = .shared,
         compass: CompassManager = .shared,
         navigation: NavigationManager = .shared,
         audio: NavigationAudioManager = .shared,
         calls: CallAlertManager = .shared,
         music: MusicManager = .shared,
         alerts: ContextualAlertManager = .shared,
         dashboard: DashboardConnectionManager = .shared,
         google: GoogleNavigationController = .shared) {
        self.location = location
        self.tripMeter = tripMeter
        self.compass = compass
        self.navigation = navigation
        self.audio = audio
        self.calls = calls
        self.music = music
        self.alerts = alerts
        self.dashboard = dashboard
        self.google = google
        wire()
        recoverInterruptedRide()
    }

    var dashboardCapabilities: DashboardCapabilityRegistry {
        DashboardCapabilityRegistry(protocolSupport: dashboard.protocolSupport,
                                    sessionEstablished: dashboard.state.isSessionActive)
    }

    /// Navigation events in a dashboard-neutral form, for a future verified Tripper Dash interface.
    private(set) lazy var dashboardFeed = DashboardNavigationFeed(registry: { [weak self] in
        self?.dashboardCapabilities ?? DashboardCapabilityRegistry(protocolSupport: .notVerified, sessionEstablished: false)
    })

    // MARK: Wiring

    private func wire() {
        location.locationUpdates
            .sink { [weak self] loc in self?.handle(location: loc) }
            .store(in: &cancellables)

        audio.$mode
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncGoogleVoice() }
            }
            .store(in: &cancellables)

        location.$latestHeading
            .compactMap { $0 }
            .sink { [weak self] heading in self?.compass.update(heading: heading) }
            .store(in: &cancellables)

        navigation.events
            .sink { [weak self] event in self?.handle(navigationEvent: event) }
            .store(in: &cancellables)

        calls.phaseChanges
            .sink { [weak self] phase in self?.handle(callPhase: phase) }
            .store(in: &cancellables)

        dashboard.$state
            .removeDuplicates()
            .scan((DashboardConnectionState.wifiDisconnected, DashboardConnectionState.wifiDisconnected)) { ($0.1, $1) }
            .sink { [weak self] pair in self?.handle(dashboardFrom: pair.0, to: pair.1) }
            .store(in: &cancellables)

        dashboard.buttonEvents
            .sink { [weak self] button in self?.handle(button: button) }
            .store(in: &cancellables)
    }

    // MARK: Dash control stick

    /// Routes a bike control-stick press. When the stick drives the map (default),
    /// left/right zoom and down recenters; Click flips to music control, where
    /// left/right change track and down toggles play/pause. iOS does not let apps
    /// set the system volume level, so the stick changes track and play state
    /// rather than a raw volume slider.
    private func handle(button: DashButton) {
        switch button {
        case .click:
            stickMode = (stickMode == .map) ? .music : .map
            alerts.post(.dashboard, key: "stick-mode", priority: .info,
                        title: stickMode == .map ? "Stick: Map zoom" : "Stick: Music",
                        message: stickMode == .map
                            ? "Left/right zoom the map, down recenters."
                            : "Left/right change track, down plays or pauses.",
                        symbol: stickMode == .map ? "plus.magnifyingglass" : "music.note", autoDismiss: 4)
        case .right:
            stickMode == .map ? google.zoomIn() : music.next()
        case .left:
            stickMode == .map ? google.zoomOut() : music.previous()
        case .down:
            stickMode == .map ? google.recenter() : music.togglePlayPause()
        }
    }

    // MARK: Screen visibility (controls sensors while not recording)

    func rideScreenAppeared() {
        screenVisible = true
        location.startLocation(for: .rideScreen)
        location.startHeading(for: .compass)
        google.refreshStatus()
        updateIdleTimer()
    }

    func rideScreenDisappeared() {
        screenVisible = false
        location.stopLocation(for: .rideScreen)
        if rideState == .idle { location.stopHeading(for: .compass) }
        updateIdleTimer()
    }

    // MARK: Ride lifecycle

    func startRide() {
        guard rideState == .idle else { return }
        let now = Date()
        tripMeter.beginRide(at: now)
        rideStartedAt = now
        rideState = .recording
        recoveredFromInterruption = false
        location.startLocation(for: .rideRecording)
        location.startHeading(for: .compass)
        alerts.startBatteryMonitoring()
        tripMeter.persist(rideState: .recording, rideStartedAt: now)
        startTicker()
        updateIdleTimer()
        alerts.post(.ride, priority: .info, title: "Ride recording started",
                    message: "Trip A is measuring this ride with phone GPS.", symbol: "record.circle", autoDismiss: 4)
    }

    func pauseRide() {
        guard rideState == .recording else { return }
        tripMeter.pauseRecording()
        rideState = .paused
        tripMeter.persist(rideState: .paused, rideStartedAt: rideStartedAt)
        location.stopLocation(for: .rideRecording)
        updateTickerNeed()
        alerts.post(.ride, priority: .info, title: "Ride paused", message: "Distance and time are not being recorded.",
                    symbol: "pause.circle", autoDismiss: 4)
    }

    func resumeRide() {
        guard rideState == .paused else { return }
        tripMeter.resumeRecording()
        rideState = .recording
        recoveredFromInterruption = false
        location.startLocation(for: .rideRecording)
        tripMeter.persist(rideState: .recording, rideStartedAt: rideStartedAt)
        startTicker()
        updateIdleTimer()
    }

    /// Finishes the ride, saves it to ride history and returns the saved log (nil if too short).
    @discardableResult
    func endRide(dataManager: DataManager) -> RideLog? {
        guard rideState != .idle else { return nil }
        rideWasAutoStarted = false
        let rideTitle = navigation.stops.last?.name ?? "Recorded ride"
        let result = tripMeter.finishRide()
        let metrics = result.metrics
        rideState = .idle
        location.stopLocation(for: .rideRecording)
        if !screenVisible { location.stopHeading(for: .compass) }
        alerts.stopBatteryMonitoring()
        if navigation.status != .idle { stopNavigation() }
        updateTickerNeed()
        updateIdleTimer()

        guard metrics.distanceKm >= 0.05 else {
            alerts.post(.ride, priority: .info, title: "Ride not saved",
                        message: "Less than 50 m was recorded.", symbol: "xmark.circle", autoDismiss: 5)
            rideStartedAt = nil
            return nil
        }

        let unitFactor = dataManager.distanceUnit == .miles ? (1 / 1.609344) : 1.0
        let distanceInUnit = metrics.distanceKm * unitFactor
        let route = RideLogBuilder.downsample(result.route, maxPoints: 2000)
        let log = RideLog(
            date: rideStartedAt ?? Date(),
            title: rideTitle,
            distance: distanceInUnit,
            durationMinutes: max(1, Int((metrics.elapsedSeconds / 60).rounded())),
            endingOdometer: dataManager.motorcycle.currentOdometer + distanceInUnit,
            notes: "Recorded with phone GPS in ReTripper Ride Mode.",
            movingMinutes: Int((metrics.movingSeconds / 60).rounded()),
            averageMovingSpeedKmh: metrics.averageMovingSpeedKmh,
            maxSpeedKmh: metrics.maxSpeedKmh,
            elevationGainMeters: metrics.elevationReliable ? metrics.elevationGainMeters : nil,
            route: route,
            source: "phone-gps"
        )
        dataManager.addRideLog(log)
        lastSavedRide = log
        rideStartedAt = nil
        alerts.post(.ride, priority: .info, title: "Ride saved",
                    message: String(format: "%.1f %@ added to ride history.", distanceInUnit, dataManager.distanceUnit.shortLabel),
                    symbol: "checkmark.circle", autoDismiss: 6)
        return log
    }

    /// Discards a recovered ride without saving it.
    func discardRecoveredRide() {
        guard recoveredFromInterruption else { return }
        _ = tripMeter.finishRide()
        rideState = .idle
        rideStartedAt = nil
        recoveredFromInterruption = false
        rideWasAutoStarted = false
        updateTickerNeed()
    }

    func appWillResignActive() {
        if rideState != .idle {
            tripMeter.persist(rideState: rideState, rideStartedAt: rideStartedAt)
        }
    }

    private func recoverInterruptedRide() {
        guard let record = tripMeter.loadRecoveryRecord(), record.rideState != .idle else { return }
        tripMeter.restore(from: record)
        rideStartedAt = record.rideStartedAt
        rideState = .paused
        recoveredFromInterruption = true
        alerts.post(.ride, key: "ride-recovered", priority: .warning, title: "Ride recovered",
                    message: "ReTripper was interrupted during a ride. Resume or end it to save.",
                    symbol: "arrow.counterclockwise.circle", autoDismiss: 10)
    }

    // MARK: Navigation

    /// Sends the chosen stops to Google and shows the route options on the map.
    func previewRoute() {
        navigation.previewRoute()
        location.startLocation(for: .navigation)
    }

    func startNavigation() {
        // Google's Navigation SDK speaks its own directions; ReTripper's voice stays
        // silent during guidance so instructions are never announced twice.
        audio.externalEngineSpeaks = true
        syncGoogleVoice()
        navigation.startGuidance()
        location.startLocation(for: .navigation)
        startTicker()
        updateIdleTimer()
    }

    func stopNavigation() {
        navigation.stopNavigation()
        location.stopLocation(for: .navigation)
        audio.externalEngineSpeaks = false
        audio.stopSpeaking()
        updateTickerNeed()
        updateIdleTimer()
    }

    /// Repeats the current direction with ReTripper's voice (on explicit rider request).
    func repeatInstruction() {
        if let text = navigation.progress?.nextInstruction {
            audio.speakOnRequest("\(RideFormat.distanceSpoken(navigation.progress?.distanceToNextManeuverMeters ?? 0)), \(text)")
        } else {
            audio.repeatLastInstruction()
        }
    }

    /// Applies the rider's guidance mode (full / important only / muted) to Google's voice.
    func syncGoogleVoice() {
        google.setVoice(audio.mode, callActive: calls.isCallInProgress)
    }

    // MARK: Event handling

    private func handle(location loc: CLLocation) {
        tripMeter.process(loc)
        compass.update(location: loc)
        if rideState == .recording || navigation.status.isActive {
            alerts.evaluateGPS(horizontalAccuracy: loc.horizontalAccuracy)
        }
    }

    private func handle(navigationEvent event: NavigationEvent) {
        switch event {
        case .started:
            alerts.post(.navigationInterruption, key: "nav-started", priority: .info, title: "Navigation started",
                        message: navigation.engineName, symbol: "location.north.line", autoDismiss: 4)
        case .stepAdvanced(let p):
            dashboardFeed.publish(progress: p)
        case .offRoute:
            alerts.post(.routeDeviation, priority: .warning, title: "Off route",
                        message: "Google is recalculating the route…", symbol: "arrow.triangle.branch", autoDismiss: 6)
        case .rerouted:
            alerts.dismiss(key: AlertCategory.routeDeviation.rawValue)
        case .failed(let message):
            alerts.post(.navigationInterruption, priority: .warning, title: "Navigation problem",
                        message: message, symbol: "exclamationmark.triangle", autoDismiss: 10)
        case .arrived(let name):
            alerts.post(.maneuver, key: "arrived", priority: .advisory, title: "Arrived",
                        message: name, symbol: "flag.checkered", autoDismiss: 8)
            location.stopLocation(for: .navigation)
        case .stopped:
            break
        }
    }

    private func handle(callPhase phase: CallPhase) {
        audio.setCallActive(calls.isCallInProgress)
        syncGoogleVoice()
        switch phase {
        case .incoming:
            alerts.post(.call, key: "call", priority: .critical, title: "Incoming call",
                        message: "Navigation and trip recording continue.", symbol: "phone.arrow.down.left", autoDismiss: nil)
        case .active, .outgoing, .onHold:
            alerts.post(.call, key: "call", priority: .advisory, title: "Call in progress",
                        message: "Voice guidance paused.", symbol: "phone.fill", autoDismiss: nil)
        case .ended:
            alerts.post(.call, key: "call", priority: .info, title: "Call ended",
                        message: "Voice guidance resumed.", symbol: "phone.down", autoDismiss: 3)
        case .none:
            alerts.dismiss(key: "call")
        }
    }

    private func handle(dashboardFrom old: DashboardConnectionState, to new: DashboardConnectionState) {
        // Auto-record: connecting to the bike (dash Wi-Fi) starts a ride, and
        // dropping that connection ends and saves it.
        if !old.isAssociated && new.isAssociated {
            autoStartRide()
        } else if old.isAssociated && !new.isAssociated {
            autoEndRide()
        }

        guard rideState != .idle || navigation.status.isActive else { return }
        if old.isAssociated && !new.isAssociated {
            alerts.post(.dashboard, priority: .warning, title: "Tripper Wi-Fi disconnected",
                        message: "Phone-side ride features continue normally.", symbol: "wifi.slash", autoDismiss: 8)
        }
    }

    /// Begins recording automatically when the bike connects (phone GPS).
    private func autoStartRide() {
        guard rideState == .idle else { return }
        rideWasAutoStarted = true
        startRide()
    }

    /// Ends and saves a ride that was auto-started, when the bike disconnects.
    /// A manually started ride is left running.
    private func autoEndRide() {
        guard rideWasAutoStarted, rideState != .idle else { return }
        endRide(dataManager: DataManager.shared)
    }

    // MARK: Ticker

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.publish(every: 1, tolerance: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in self?.tick(now) }
    }

    private func updateTickerNeed() {
        if rideState != .recording && !navigation.status.isActive {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func tick(_ now: Date) {
        tripMeter.tick(now: now)
        alerts.tick(now: now)
        if rideState == .recording,
           lastReminderCheck.map({ now.timeIntervalSince($0) > 300 }) ?? true {
            lastReminderCheck = now
            alerts.evaluateReminders(dataManager: DataManager.shared, currentTripKm: tripMeter.tripA.metrics.distanceKm, now: now)
        }
    }

    private func updateIdleTimer() {
        // Keep the screen awake only while the ride screen is visible and actively used.
        UIApplication.shared.isIdleTimerDisabled = screenVisible && (rideState == .recording || navigation.status.isActive)
    }
}

// MARK: - Helpers

enum RideLogBuilder {
    static func downsample(_ points: [RoutePoint], maxPoints: Int) -> [RoutePoint] {
        guard points.count > maxPoints, maxPoints > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { points[Int((Double($0) * step).rounded())] }
    }
}

enum RideFormat {
    static func distanceSpoken(_ meters: Double) -> String {
        "In " + GuidanceAnnouncementPlanner.spokenDistance(meters)
    }

    static func distance(_ meters: Double) -> String {
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        return "\(max(0, Int((meters / 10).rounded()) * 10)) m"
    }

    static func speedKmh(_ mps: Double) -> String { String(format: "%.0f", max(0, mps * 3.6)) }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}
