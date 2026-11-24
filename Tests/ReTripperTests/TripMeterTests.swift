//
//  TripMeterTests.swift
//  ReTripperTests
//
//  Trip meter calculations, GPS sample filtering, lifecycle and recovery.
//

import XCTest
import CoreLocation
@testable import ReTripper

final class TripAccumulatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// ~0.0001° latitude ≈ 11.1 m.
    private func sample(_ i: Int, latStep: Double = 0.0001, dt: TimeInterval = 1, speed: Double = 11,
                        accuracy: Double = 5, altitude: Double = 100, vAcc: Double = 3) -> LocationSample {
        LocationSample(latitude: 12.0 + Double(i) * latStep, longitude: 77.0, altitude: altitude,
                       horizontalAccuracy: accuracy, verticalAccuracy: vAcc, speed: speed, course: 0,
                       timestamp: t0.addingTimeInterval(Double(i) * dt))
    }

    func testMovingSamplesAccumulateDistanceAndMovingTime() {
        var acc = TripAccumulator()
        XCTAssertEqual(acc.ingest(sample(0)), .firstFix)
        for i in 1...10 { XCTAssertEqual(acc.ingest(sample(i)), .accepted) }
        XCTAssertEqual(acc.metrics.distanceMeters, 111.3, accuracy: 2.0)
        XCTAssertEqual(acc.metrics.movingSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(acc.metrics.averageMovingSpeedMps, 11.1, accuracy: 0.3)
    }

    func testRejectsInaccurateAndInvalidSamples() {
        var acc = TripAccumulator()
        XCTAssertEqual(acc.ingest(sample(0, accuracy: 80)), .rejectedInvalidAccuracy)
        XCTAssertEqual(acc.ingest(sample(0, accuracy: -1)), .rejectedInvalidAccuracy)
        var bad = sample(0)
        bad.latitude = .nan
        XCTAssertEqual(acc.ingest(bad), .rejectedInvalidAccuracy)
        XCTAssertEqual(acc.metrics.rejectedSamples, 3)
        XCTAssertEqual(acc.metrics.distanceMeters, 0)
    }

    func testRejectsOutOfOrderAndDuplicateTimestamps() {
        var acc = TripAccumulator()
        acc.ingest(sample(5))
        XCTAssertEqual(acc.ingest(sample(4)), .rejectedOutOfOrder)
        XCTAssertEqual(acc.ingest(sample(5)), .rejectedOutOfOrder)
        XCTAssertEqual(acc.metrics.distanceMeters, 0)
    }

    func testRejectsStaleCachedFix() {
        var acc = TripAccumulator()
        let s = sample(0)
        XCTAssertEqual(acc.ingest(s, receivedAt: s.timestamp.addingTimeInterval(60)), .rejectedStale)
    }

    func testRejectsImplausibleGPSJump() {
        var acc = TripAccumulator()
        acc.ingest(sample(0))
        // 0.01° ≈ 1.1 km in one second = ~4000 km/h.
        XCTAssertEqual(acc.ingest(sample(1, latStep: 0.01)), .rejectedImplausibleJump)
        XCTAssertEqual(acc.metrics.distanceMeters, 0)
        // Next sane sample is measured from the last good fix.
        XCTAssertEqual(acc.ingest(sample(2, latStep: 0.0001)), .accepted)
    }

    func testStationaryDriftDoesNotAddDistance() {
        var acc = TripAccumulator()
        acc.ingest(sample(0, speed: 0))
        for i in 1...30 {
            // Wander ±3 m around the same point while stopped.
            var s = sample(0, speed: 0)
            s.latitude += (i % 2 == 0 ? 0.00002 : -0.00002)
            s.timestamp = t0.addingTimeInterval(Double(i))
            XCTAssertEqual(acc.ingest(s), .stationaryDrift)
        }
        XCTAssertEqual(acc.metrics.distanceMeters, 0)
        XCTAssertEqual(acc.metrics.movingSeconds, 0)
    }

    func testStoppedTimeIsElapsedMinusMoving() {
        var acc = TripAccumulator()
        for i in 0...10 { acc.ingest(sample(i)) }
        acc.addElapsed(60)
        XCTAssertEqual(acc.metrics.stoppedSeconds, 50, accuracy: 0.001)
    }

    func testElevationGainUsesHysteresisAndAccuracy() {
        var acc = TripAccumulator()
        let altitudes: [Double] = [100, 101, 102, 104, 103, 107, 110, 108, 115]
        for (i, alt) in altitudes.enumerated() { acc.ingest(sample(i, altitude: alt)) }
        // Gains counted only for climbs ≥ 3 m from the reference: 100→104, 104→107, 107→110, 110→115.
        XCTAssertEqual(acc.metrics.elevationGainMeters, 15, accuracy: 0.001)
        XCTAssertTrue(acc.metrics.elevationReliable)

        var noisy = TripAccumulator()
        for (i, alt) in altitudes.enumerated() { noisy.ingest(sample(i, altitude: alt, vAcc: 30)) }
        XCTAssertEqual(noisy.metrics.elevationGainMeters, 0)
        XCTAssertFalse(noisy.metrics.elevationReliable)
    }

    func testBreakSegmentPreventsGapDistance() {
        var acc = TripAccumulator()
        acc.ingest(sample(0))
        acc.ingest(sample(1))
        let before = acc.metrics.distanceMeters
        acc.breakSegment()
        XCTAssertEqual(acc.ingest(sample(500, dt: 1)), .firstFix)
        XCTAssertEqual(acc.metrics.distanceMeters, before)
    }

    func testDurationFormatting() {
        XCTAssertEqual(TripMetrics.formatDuration(59), "00:59")
        XCTAssertEqual(TripMetrics.formatDuration(3_725), "1:02:05")
    }
}

@MainActor
final class TripMeterManagerTests: XCTestCase {
    /// Each test gets its own recovery file so tests never touch real ride data.
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("trip-\(UUID().uuidString).json")

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    private func location(_ i: Int, at date: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 12 + Double(i) * 0.0001, longitude: 77),
                   altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 3, course: 0, speed: 11, timestamp: date)
    }

    func testLifecycleElapsedTimeExcludesPause() {
        let meter = TripMeterManager(storageURL: url)
        let start = Date()
        meter.beginRide(at: start)
        meter.tick(now: start.addingTimeInterval(30))
        meter.pauseRecording(at: start.addingTimeInterval(40))
        meter.tick(now: start.addingTimeInterval(100))   // ignored while paused
        meter.resumeRecording(at: start.addingTimeInterval(100))
        meter.tick(now: start.addingTimeInterval(110))
        let result = meter.finishRide(at: start.addingTimeInterval(120))
        XCTAssertEqual(result.metrics.elapsedSeconds, 60, accuracy: 0.001)
    }

    func testSamplesIgnoredWhenNotRecording() {
        let meter = TripMeterManager(storageURL: url)
        let now = Date()
        meter.process(location(0, at: now), receivedAt: now)
        meter.process(location(1, at: now.addingTimeInterval(1)), receivedAt: now.addingTimeInterval(1))
        XCTAssertEqual(meter.tripA.metrics.distanceMeters, 0)
    }

    func testTripBAccumulatesAcrossRidesAndTripAResets() {
        let meter = TripMeterManager(storageURL: url)
        var now = Date()
        meter.beginRide(at: now)
        for i in 0...5 {
            now = now.addingTimeInterval(1)
            meter.process(location(i, at: now), receivedAt: now)
        }
        _ = meter.finishRide(at: now)
        let firstB = meter.tripB.metrics.distanceMeters
        XCTAssertGreaterThan(firstB, 40)

        meter.beginRide(at: now)
        XCTAssertEqual(meter.tripA.metrics.distanceMeters, 0)
        for i in 10...15 {
            now = now.addingTimeInterval(1)
            meter.process(location(i, at: now), receivedAt: now)
        }
        XCTAssertGreaterThan(meter.tripB.metrics.distanceMeters, firstB + 40)
        meter.reset(.tripB)
        XCTAssertEqual(meter.tripB.metrics.distanceMeters, 0)
    }

    func testRecoveryRecordRoundTrip() {
        let meter = TripMeterManager(storageURL: url)
        var now = Date()
        let started = now
        meter.beginRide(at: now)
        for i in 0...5 {
            now = now.addingTimeInterval(1)
            meter.process(location(i, at: now), receivedAt: now)
        }
        meter.persist(rideState: .recording, rideStartedAt: started)

        let relaunched = TripMeterManager(storageURL: url)
        guard let record = relaunched.loadRecoveryRecord() else { return XCTFail("No recovery record") }
        XCTAssertEqual(record.rideState, .recording)
        relaunched.restore(from: record)
        XCTAssertEqual(relaunched.tripA.metrics.distanceMeters, meter.tripA.metrics.distanceMeters, accuracy: 0.01)
        XCTAssertFalse(relaunched.isRecording)
        relaunched.clearRecoveryRecord()
        XCTAssertNil(relaunched.loadRecoveryRecord())
    }

    func testRouteDownsampling() {
        let points = (0..<5000).map { RoutePoint(latitude: Double($0), longitude: 0, timestamp: Date()) }
        let down = RideLogBuilder.downsample(points, maxPoints: 100)
        XCTAssertEqual(down.count, 100)
        XCTAssertEqual(down.first, points.first)
        XCTAssertEqual(down.last, points.last)
    }
}
