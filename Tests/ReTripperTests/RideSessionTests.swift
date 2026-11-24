//
//  RideSessionTests.swift
//  ReTripperTests
//
//  Alerts, call state, music availability, audio interruption handling,
//  dashboard capability gating, connection states and ride session lifecycle.
//

import XCTest
import CoreLocation
@testable import ReTripper

final class AlertQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func alert(_ key: String, _ category: AlertCategory = .gpsSignal, _ priority: AlertPriority = .warning,
                       at date: Date, ttl: TimeInterval? = 5) -> RideAlert {
        RideAlert(key: key, category: category, priority: priority, title: key, message: "", symbol: "circle",
                  createdAt: date, expiresAt: ttl.map { date.addingTimeInterval($0) })
    }

    func testDeduplicatesActiveAlert() {
        var q = AlertQueue()
        XCTAssertTrue(q.post(alert("gps", at: t0), now: t0))
        XCTAssertFalse(q.post(alert("gps", at: t0.addingTimeInterval(1)), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(q.active.count, 1)
    }

    func testCooldownSuppressesRepeatsAfterExpiry() {
        var q = AlertQueue()
        q.post(alert("gps", at: t0), now: t0)
        q.expire(now: t0.addingTimeInterval(10))
        XCTAssertTrue(q.active.isEmpty)
        // GPS cooldown is 120 s.
        XCTAssertFalse(q.post(alert("gps", at: t0.addingTimeInterval(20)), now: t0.addingTimeInterval(20)))
        XCTAssertTrue(q.post(alert("gps", at: t0.addingTimeInterval(200)), now: t0.addingTimeInterval(200)))
    }

    func testPriorityOrderingAndAutoDismiss() {
        var q = AlertQueue()
        q.post(alert("info", .ride, .info, at: t0), now: t0)
        q.post(alert("call", .call, .critical, at: t0, ttl: nil), now: t0)
        q.post(alert("fuel", .fuel, .advisory, at: t0), now: t0)
        XCTAssertEqual(q.top?.key, "call")
        q.expire(now: t0.addingTimeInterval(6))
        XCTAssertEqual(q.active.map { $0.key }, ["call"])
        q.dismiss(key: "call")
        XCTAssertNil(q.top)
    }

    func testMaxActiveAlerts() {
        var q = AlertQueue()
        for i in 0..<10 { q.post(alert("a\(i)", .ride, .info, at: t0), now: t0) }
        XCTAssertEqual(q.active.count, q.maxActive)
    }

    func testServiceAndFuelReminders() {
        let now = t0
        XCTAssertTrue(ServiceReminder.isServiceDue(currentOdometer: 6000, lastServiceOdometer: 500,
                                                   lastServiceDate: now, intervalKm: 5000, intervalDays: 365,
                                                   unitToKm: 1, now: now))
        XCTAssertFalse(ServiceReminder.isServiceDue(currentOdometer: 1000, lastServiceOdometer: 500,
                                                    lastServiceDate: now, intervalKm: 5000, intervalDays: 365,
                                                    unitToKm: 1, now: now))
        XCTAssertFalse(ServiceReminder.isServiceDue(currentOdometer: 9000, lastServiceOdometer: nil,
                                                    lastServiceDate: nil, intervalKm: 5000, intervalDays: 365,
                                                    unitToKm: 1, now: now))
        XCTAssertEqual(ServiceReminder.kmSinceRefuel(currentOdometer: 200, lastFuelOdometer: 100,
                                                     currentTripKm: 20, unitToKm: 1) ?? 0, 120, accuracy: 0.001)
        XCTAssertNil(ServiceReminder.kmSinceRefuel(currentOdometer: 200, lastFuelOdometer: nil,
                                                   currentTripKm: 20, unitToKm: 1))
    }
}

final class CallAndCompassTests: XCTestCase {
    func testCallPhaseResolution() {
        XCTAssertEqual(CallPhaseResolver.phase(for: []), .none)
        XCTAssertEqual(CallPhaseResolver.phase(for: [CallSnapshot(isOutgoing: false, hasConnected: false, hasEnded: false, isOnHold: false)]), .incoming)
        XCTAssertEqual(CallPhaseResolver.phase(for: [CallSnapshot(isOutgoing: true, hasConnected: false, hasEnded: false, isOnHold: false)]), .outgoing)
        XCTAssertEqual(CallPhaseResolver.phase(for: [CallSnapshot(isOutgoing: false, hasConnected: true, hasEnded: false, isOnHold: false)]), .active)
        XCTAssertEqual(CallPhaseResolver.phase(for: [CallSnapshot(isOutgoing: false, hasConnected: true, hasEnded: false, isOnHold: true)]), .onHold)
        XCTAssertEqual(CallPhaseResolver.phase(for: [CallSnapshot(isOutgoing: false, hasConnected: true, hasEnded: true, isOnHold: false)]), .ended)
    }

    func testCompassDirections() {
        XCTAssertEqual(CompassMath.direction(for: 0), "N")
        XCTAssertEqual(CompassMath.direction(for: 44), "NE")
        XCTAssertEqual(CompassMath.direction(for: 359), "N")
        XCTAssertEqual(CompassMath.direction(for: -90), "W")
        XCTAssertEqual(CompassMath.fineDirection(for: 202.5), "SSW")
        XCTAssertEqual(CompassMath.calibration(forAccuracy: -1), .needsCalibration)
        XCTAssertEqual(CompassMath.calibration(forAccuracy: 10), .good)
        XCTAssertEqual(CompassMath.calibration(forAccuracy: 25), .fair)
    }
}

@MainActor
final class FakeMusicProvider: MusicProvider {
    let kind: MusicProviderKind
    var onChange: (() -> Void)?
    var availability: MusicAvailability
    var nowPlaying: NowPlaying?
    var playbackState: PlaybackState = .paused
    var toggles = 0

    init(kind: MusicProviderKind, availability: MusicAvailability) {
        self.kind = kind
        self.availability = availability
    }
    func requestAuthorization() async { availability = .available; onChange?() }
    func togglePlayPause() { toggles += 1 }
    func next() {}
    func previous() {}
}

@MainActor
final class MusicAndAudioTests: XCTestCase {
    func testSpotifyReportsNotConfigured() {
        let spotify = SpotifyMusicProvider()
        if case .notConfigured = spotify.availability {} else { XCTFail("Spotify must not claim availability") }
        XCTAssertNil(spotify.nowPlaying)
    }

    func testMusicManagerProviderSelectionAndAuthorization() async {
        let apple = FakeMusicProvider(kind: .appleMusic, availability: .needsAuthorization)
        let spotify = FakeMusicProvider(kind: .spotify, availability: .notConfigured("x"))
        let manager = MusicManager(providers: [apple, spotify])
        XCTAssertEqual(manager.availability, .needsAuthorization)
        await manager.requestAuthorization()
        XCTAssertEqual(manager.availability, .available)
        manager.togglePlayPause()
        XCTAssertEqual(apple.toggles, 1)
        manager.select(.spotify)
        XCTAssertEqual(manager.availability, .notConfigured("x"))
    }

    func testGuidanceSuppressedDuringCallAndRepeatedAfter() {
        let audio = NavigationAudioManager()
        audio.mode = .full
        audio.setCallActive(true)
        audio.announceEvent("Recalculating route")
        XCTAssertFalse(audio.isSpeaking)
        XCTAssertEqual(audio.lastInstruction, "Recalculating route")
        audio.setCallActive(false)
        XCTAssertTrue(audio.isSpeaking)
        audio.stopSpeaking()
        XCTAssertFalse(audio.isSpeaking)
    }

    func testNoDuplicateVoiceWhenExternalEngineSpeaks() {
        let audio = NavigationAudioManager()
        audio.mode = .full
        audio.externalEngineSpeaks = true
        audio.announceEvent("Turn left")
        XCTAssertFalse(audio.isSpeaking)
        XCTAssertNil(audio.lastInstruction)
    }
}

@MainActor
final class DashboardTests: XCTestCase {
    func testAllCapabilitiesUnavailableWithoutVerifiedProtocol() {
        let registry = DashboardCapabilityRegistry(protocolSupport: .notVerified, sessionEstablished: false)
        for cap in DashboardCapability.allCases {
            XCTAssertFalse(registry.availability(of: cap).isAvailable, "\(cap) must be gated")
        }
        XCTAssertFalse(registry.anyAvailable)
        XCTAssertFalse(registry.output.send(.heading(degrees: 90)))
    }

    func testNavigationFeedIsGatedUntilVerifiedProtocol() {
        let feed = DashboardNavigationFeed(registry: {
            DashboardCapabilityRegistry(protocolSupport: .notVerified, sessionEstablished: false)
        })
        let progress = RouteProgress(stepIndex: 0, nextManeuver: .left, nextInstruction: "Turn left",
                                     nextRoadName: "MG Road", distanceToNextManeuverMeters: 200,
                                     remainingDistanceMeters: 1000, remainingSeconds: 100, fractionComplete: 0.5)
        XCTAssertFalse(feed.publish(progress: progress))
        XCTAssertEqual(feed.sentCount, 0)
        XCTAssertEqual(feed.lastMessage, .maneuver(symbol: "left", distanceMeters: 200, road: "MG Road"))
    }

    func testGoogleMapsWithoutKeyReportsMissingConfiguration() {
        // Only meaningful when the test host was built without a key.
        if AppSecretsConfiguration.googleMapsAPIKey == nil {
            XCTAssertEqual(GoogleNavigationController.shared.status, .missingAPIKey)
            XCTAssertNil(GoogleNavigationController.shared.makeOrReuseMapView())
        }
    }

    func testConnectionStateSemantics() {
        XCTAssertFalse(DashboardConnectionState.wifiConfigured(ssid: "RE").isAssociated)
        XCTAssertTrue(DashboardConnectionState.wifiAssociated(ssid: "RE").isAssociated)
        XCTAssertFalse(DashboardConnectionState.wifiAssociated(ssid: "RE").isSessionActive)
        XCTAssertEqual(DashboardConnectionState.wifiConfigured(ssid: "RE_1").ssid, "RE_1")
        XCTAssertNil(DashboardConnectionState.wifiDisconnected.ssid)
    }

    func testSessionIsNeverFakedOnAssociatedWifi() {
        let manager = DashboardConnectionManager()
        manager.state = .wifiAssociated(ssid: "RE_TRIPPER")
        manager.verifyDashboardSession()
        XCTAssertEqual(manager.state, .wifiAssociated(ssid: "RE_TRIPPER"))
        XCTAssertFalse(manager.state.isSessionActive)
        XCTAssertNotNil(manager.diagnosticMessage)
    }

    func testDisconnectReturnsToDisconnected() {
        let manager = DashboardConnectionManager()
        manager.state = .wifiAssociated(ssid: "RE")
        manager.disconnect()
        XCTAssertEqual(manager.state, .wifiDisconnected)
    }
}

@MainActor
final class RideSessionLifecycleTests: XCTestCase {
    func testStartPauseResumeEndWithoutDistanceDoesNotSave() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let meter = TripMeterManager(storageURL: url)
        let session = RideSessionManager(tripMeter: meter, navigation: makeNavigationManager())

        XCTAssertEqual(session.rideState, .idle)
        session.startRide()
        XCTAssertEqual(session.rideState, .recording)
        XCTAssertTrue(meter.isRecording)
        session.startRide()   // ignored
        XCTAssertEqual(session.rideState, .recording)

        session.pauseRide()
        XCTAssertEqual(session.rideState, .paused)
        XCTAssertFalse(meter.isRecording)

        session.resumeRide()
        XCTAssertEqual(session.rideState, .recording)

        let before = DataManager.shared.rideLogs.count
        XCTAssertNil(session.endRide(dataManager: DataManager.shared))
        XCTAssertEqual(session.rideState, .idle)
        XCTAssertEqual(DataManager.shared.rideLogs.count, before)
        XCTAssertNil(meter.loadRecoveryRecord())
    }

    func testInterruptedRideIsRecoveredPaused() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = TripMeterManager(storageURL: url)
        first.beginRide()
        first.persist(rideState: .recording, rideStartedAt: Date())

        let session = RideSessionManager(tripMeter: TripMeterManager(storageURL: url),
                                         navigation: makeNavigationManager())
        XCTAssertEqual(session.rideState, .paused)
        XCTAssertTrue(session.recoveredFromInterruption)
        session.discardRecoveredRide()
        XCTAssertEqual(session.rideState, .idle)
    }

    func testPhoneFeaturesWorkWithoutMotorcycle() {
        let session = RideSessionManager(tripMeter: TripMeterManager(storageURL: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("s-\(UUID().uuidString).json")),
                                         navigation: makeNavigationManager())
        XCTAssertFalse(session.dashboard.state.isSessionActive)
        session.startRide()
        XCTAssertEqual(session.rideState, .recording)
        _ = session.endRide(dataManager: DataManager.shared)
    }
}
