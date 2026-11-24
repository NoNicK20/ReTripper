//
//  TripMeterManager.swift
//  ReTripper
//
//  Dual trip meter (Trip A / Trip B) fed by phone GPS.
//  Trip A covers the current ride and is saved to ride history when the ride ends.
//  Trip B keeps accumulating across rides until the rider resets it.
//  State is persisted so a ride survives app termination or interruptions.
//

import Foundation
import CoreLocation
import Combine

/// Snapshot written to disk so an interrupted ride can be recovered.
struct TripRecoveryRecord: Codable, Equatable {
    var rideState: RideState
    var rideStartedAt: Date?
    var tripA: TripAccumulator
    var tripB: TripAccumulator
    var route: [RoutePoint]
    var savedAt: Date
}

@MainActor
final class TripMeterManager: ObservableObject {
    static let shared = TripMeterManager()

    @Published private(set) var tripA = TripAccumulator()
    @Published private(set) var tripB = TripAccumulator()
    @Published private(set) var route: [RoutePoint] = []
    @Published private(set) var currentSpeedMps: Double = 0
    @Published private(set) var lastVerdict: SampleVerdict?
    @Published var displayedSlot: TripSlot = .tripA

    private(set) var isRecording = false
    private var recordingSegmentStart: Date?
    private var samplesSinceSave = 0
    private let storageURL: URL
    private let maxRoutePoints = 20_000
    private let minRoutePointSpacing: Double = 10

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("retripper_active_trip.json")
        }
    }

    func metrics(for slot: TripSlot) -> TripMetrics {
        slot == .tripA ? tripA.metrics : tripB.metrics
    }

    // MARK: Lifecycle

    /// Starts a fresh ride: Trip A is reset, Trip B continues.
    func beginRide(at date: Date = Date()) {
        tripA = TripAccumulator()
        tripB.breakSegment()
        route = []
        resumeRecording(at: date)
    }

    func pauseRecording(at date: Date = Date()) {
        guard isRecording else { return }
        flushElapsed(until: date)
        isRecording = false
        recordingSegmentStart = nil
        tripA.breakSegment()
        tripB.breakSegment()
        currentSpeedMps = 0
    }

    func resumeRecording(at date: Date = Date()) {
        guard !isRecording else { return }
        isRecording = true
        recordingSegmentStart = date
    }

    /// Ends recording and returns the final Trip A metrics and recorded route.
    func finishRide(at date: Date = Date()) -> (metrics: TripMetrics, route: [RoutePoint]) {
        pauseRecording(at: date)
        let result = (metrics: tripA.metrics, route: route)
        clearRecoveryRecord()
        return result
    }

    func reset(_ slot: TripSlot) {
        switch slot {
        case .tripA: tripA = TripAccumulator(); route = []
        case .tripB: tripB = TripAccumulator()
        }
    }

    /// Adds wall-clock time to the elapsed counters. Called by the session's single 1 Hz tick.
    func tick(now: Date = Date()) {
        guard isRecording else { return }
        flushElapsed(until: now)
    }

    private func flushElapsed(until date: Date) {
        guard let start = recordingSegmentStart else { return }
        let delta = date.timeIntervalSince(start)
        if delta > 0 {
            tripA.addElapsed(delta)
            tripB.addElapsed(delta)
        }
        recordingSegmentStart = date
    }

    // MARK: Samples

    func process(_ location: CLLocation, receivedAt: Date = Date()) {
        currentSpeedMps = location.speed >= 0 ? location.speed : 0
        guard isRecording else { return }
        let sample = LocationSample(location)
        let verdict = tripA.ingest(sample, receivedAt: receivedAt)
        tripB.ingest(sample, receivedAt: receivedAt)
        lastVerdict = verdict
        if verdict == .accepted || verdict == .firstFix {
            appendRoutePoint(sample)
        }
        samplesSinceSave += 1
        if samplesSinceSave >= 15 {
            samplesSinceSave = 0
            persist(rideState: .recording, rideStartedAt: nil)
        }
    }

    private func appendRoutePoint(_ sample: LocationSample) {
        if let last = route.last {
            let lastLocation = CLLocation(latitude: last.latitude, longitude: last.longitude)
            if sample.clLocation.distance(from: lastLocation) < minRoutePointSpacing { return }
        }
        route.append(RoutePoint(latitude: sample.latitude, longitude: sample.longitude, timestamp: sample.timestamp))
        if route.count > maxRoutePoints {
            // Thin the route by dropping every other point in the older half.
            let half = route.count / 2
            let thinned = route[..<half].enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
            route = thinned + route[half...]
        }
    }

    // MARK: Recovery

    private var recoveryStartedAt: Date?

    func persist(rideState: RideState, rideStartedAt: Date?) {
        if let rideStartedAt { recoveryStartedAt = rideStartedAt }
        let record = TripRecoveryRecord(rideState: rideState, rideStartedAt: recoveryStartedAt,
                                        tripA: tripA, tripB: tripB, route: route, savedAt: Date())
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Non-fatal: recovery is best effort.
        }
    }

    func loadRecoveryRecord() -> TripRecoveryRecord? {
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode(TripRecoveryRecord.self, from: data)
    }

    /// Restores trip state from disk. Recording stays paused; the rider chooses to resume.
    func restore(from record: TripRecoveryRecord) {
        tripA = record.tripA
        tripB = record.tripB
        tripA.breakSegment()
        tripB.breakSegment()
        route = record.route
        recoveryStartedAt = record.rideStartedAt
        isRecording = false
        recordingSegmentStart = nil
    }

    func clearRecoveryRecord() {
        try? FileManager.default.removeItem(at: storageURL)
        recoveryStartedAt = nil
    }
}
