//
//  TripModels.swift
//  ReTripper
//
//  Phone-derived trip computer models and the pure GPS-filtering accumulator.
//  Everything here is measured by the iPhone's GPS (CoreLocation). None of it
//  is motorcycle telemetry: no fuel use, odometer, RPM or sensor data is read or invented.
//

import Foundation
import CoreLocation

// MARK: - Ride lifecycle

enum RideState: String, Codable, Equatable {
    case idle
    case recording
    case paused
}

enum TripSlot: String, Codable, CaseIterable, Identifiable {
    case tripA = "TRIP A"
    case tripB = "TRIP B"
    var id: String { rawValue }
}

// MARK: - Location sample (decoupled from CLLocation so it can be tested and persisted)

struct LocationSample: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    /// Reported ground speed in m/s; negative when invalid.
    var speed: Double
    /// Reported course in degrees; negative when invalid.
    var course: Double
    var timestamp: Date

    init(latitude: Double, longitude: Double, altitude: Double = 0, horizontalAccuracy: Double = 5,
         verticalAccuracy: Double = -1, speed: Double = -1, course: Double = -1, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }

    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  altitude: location.altitude,
                  horizontalAccuracy: location.horizontalAccuracy,
                  verticalAccuracy: location.verticalAccuracy,
                  speed: location.speed,
                  course: location.course,
                  timestamp: location.timestamp)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    func distance(to other: LocationSample) -> Double {
        clLocation.distance(from: other.clLocation)
    }
}

struct RoutePoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Trip metrics

struct TripMetrics: Codable, Equatable {
    var distanceMeters: Double = 0
    var elapsedSeconds: TimeInterval = 0
    var movingSeconds: TimeInterval = 0
    var elevationGainMeters: Double = 0
    var maxSpeedMps: Double = 0
    var acceptedSamples: Int = 0
    var rejectedSamples: Int = 0
    /// False until enough samples with good vertical accuracy were seen.
    var elevationReliable: Bool = false

    var stoppedSeconds: TimeInterval { max(0, elapsedSeconds - movingSeconds) }

    var averageMovingSpeedMps: Double {
        movingSeconds > 1 ? distanceMeters / movingSeconds : 0
    }

    var distanceKm: Double { distanceMeters / 1000 }
    var averageMovingSpeedKmh: Double { averageMovingSpeedMps * 3.6 }
    var maxSpeedKmh: Double { maxSpeedMps * 3.6 }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Sample verdicts

enum SampleVerdict: Equatable {
    case accepted
    case firstFix
    case rejectedInvalidAccuracy
    case rejectedOutOfOrder
    case rejectedStale
    case rejectedImplausibleJump
    case stationaryDrift
}

// MARK: - Accumulator (pure logic)

/// Turns a stream of GPS samples into trip distance, moving time and elevation gain,
/// filtering out inaccurate fixes, stale/out-of-order timestamps, GPS jumps and stationary drift.
struct TripAccumulator: Codable, Equatable {
    struct Config: Codable, Equatable {
        var maxHorizontalAccuracy: Double = 25
        var maxVerticalAccuracyForElevation: Double = 10
        var movingSpeedThresholdMps: Double = 1.0      // ~3.6 km/h
        var maxPlausibleSpeedMps: Double = 75          // ~270 km/h — beyond this is a GPS jump
        var maxStaleAge: TimeInterval = 10             // cached fixes older than this are ignored
        var maxSegmentGap: TimeInterval = 30           // longer gaps are not counted as moving time
        var elevationHysteresisMeters: Double = 3
        var minElevationSamples: Int = 5
    }

    var config = Config()
    private(set) var metrics = TripMetrics()
    private(set) var lastAccepted: LocationSample?
    private var elevationReference: Double?
    private var goodElevationSamples: Int = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one sample. `receivedAt` is the wall-clock time the sample arrived (defaults to its own timestamp).
    @discardableResult
    mutating func ingest(_ sample: LocationSample, receivedAt: Date? = nil) -> SampleVerdict {
        let now = receivedAt ?? sample.timestamp

        guard sample.horizontalAccuracy >= 0, sample.horizontalAccuracy <= config.maxHorizontalAccuracy,
              sample.latitude.isFinite, sample.longitude.isFinite,
              abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else {
            metrics.rejectedSamples += 1
            return .rejectedInvalidAccuracy
        }
        if now.timeIntervalSince(sample.timestamp) > config.maxStaleAge {
            metrics.rejectedSamples += 1
            return .rejectedStale
        }
        guard let previous = lastAccepted else {
            lastAccepted = sample
            metrics.acceptedSamples += 1
            updateElevation(sample)
            return .firstFix
        }
        let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else {
            metrics.rejectedSamples += 1
            return .rejectedOutOfOrder
        }

        let distance = sample.distance(to: previous)
        let derivedSpeed = distance / dt
        if derivedSpeed > config.maxPlausibleSpeedMps {
            metrics.rejectedSamples += 1
            return .rejectedImplausibleJump
        }

        let reportedSpeed = sample.speed >= 0 ? sample.speed : derivedSpeed
        let isMoving = reportedSpeed >= config.movingSpeedThresholdMps
        // While stopped, small position changes within the accuracy circle are drift, not travel.
        let driftRadius = max(sample.horizontalAccuracy, previous.horizontalAccuracy, 5)
        if !isMoving && distance < driftRadius {
            metrics.acceptedSamples += 1
            // Keep the earlier anchor so drift cannot accumulate, but advance time.
            lastAccepted?.timestamp = sample.timestamp
            return .stationaryDrift
        }

        metrics.distanceMeters += distance
        if isMoving && dt <= config.maxSegmentGap {
            metrics.movingSeconds += dt
        }
        metrics.maxSpeedMps = max(metrics.maxSpeedMps, min(reportedSpeed, config.maxPlausibleSpeedMps))
        metrics.acceptedSamples += 1
        updateElevation(sample)
        lastAccepted = sample
        return .accepted
    }

    /// Forget the last fix (e.g. after a pause) so the gap is not counted as distance.
    mutating func breakSegment() {
        lastAccepted = nil
    }

    mutating func addElapsed(_ seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        metrics.elapsedSeconds += seconds
    }

    private mutating func updateElevation(_ sample: LocationSample) {
        guard sample.verticalAccuracy >= 0, sample.verticalAccuracy <= config.maxVerticalAccuracyForElevation else { return }
        goodElevationSamples += 1
        if goodElevationSamples >= config.minElevationSamples { metrics.elevationReliable = true }
        guard let reference = elevationReference else {
            elevationReference = sample.altitude
            return
        }
        let delta = sample.altitude - reference
        if delta >= config.elevationHysteresisMeters {
            metrics.elevationGainMeters += delta
            elevationReference = sample.altitude
        } else if delta <= -config.elevationHysteresisMeters {
            elevationReference = sample.altitude
        }
    }
}
