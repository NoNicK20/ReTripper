//
//  CompassManager.swift
//  ReTripper
//
//  Digital compass from CoreLocation heading (magnetometer) and GPS course.
//  While riding, the magnetometer is disturbed by the motorcycle and the phone
//  mount, so a valid GPS course is preferred when moving.
//

import Foundation
import CoreLocation
import Combine

enum CompassReference: String, CaseIterable, Identifiable, Codable {
    case trueNorth = "True North"
    case magneticNorth = "Magnetic North"
    var id: String { rawValue }
}

enum HeadingSource: String, Equatable {
    case gpsCourse = "GPS course"
    case magnetometer = "Magnetometer"
    case unavailable = "Unavailable"
}

enum CalibrationStatus: String, Equatable {
    case good = "Calibrated"
    case fair = "Fair accuracy"
    case needsCalibration = "Needs calibration"
    case unknown = "Unknown"
}

enum CompassMath {
    static let cardinalNames = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    static let eightPointNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// 8-point direction (cardinal + intercardinal).
    static func direction(for degrees: Double) -> String {
        let index = Int((normalize(degrees) + 22.5) / 45) % 8
        return eightPointNames[index]
    }

    /// 16-point direction.
    static func fineDirection(for degrees: Double) -> String {
        let index = Int((normalize(degrees) + 11.25) / 22.5) % 16
        return cardinalNames[index]
    }

    static func calibration(forAccuracy accuracy: Double) -> CalibrationStatus {
        if accuracy < 0 { return .needsCalibration }
        if accuracy <= 15 { return .good }
        if accuracy <= 30 { return .fair }
        return .needsCalibration
    }
}

@MainActor
final class CompassManager: ObservableObject {
    static let shared = CompassManager()

    @Published var reference: CompassReference = .trueNorth
    @Published private(set) var magneticHeading: Double?
    @Published private(set) var trueHeading: Double?
    @Published private(set) var headingAccuracy: Double = -1
    @Published private(set) var gpsCourse: Double?
    @Published private(set) var source: HeadingSource = .unavailable

    let sensorAvailable: Bool = CLLocationManager.headingAvailable()
    private let minimumCourseSpeedMps: Double = 2.5

    /// Heading shown to the rider for the selected reference.
    var displayedHeading: Double? {
        if let course = gpsCourse, reference == .trueNorth { return course }
        switch reference {
        case .trueNorth: return trueHeading ?? magneticHeading
        case .magneticNorth: return magneticHeading
        }
    }

    var calibration: CalibrationStatus {
        magneticHeading == nil ? .unknown : CompassMath.calibration(forAccuracy: headingAccuracy)
    }

    var directionText: String {
        guard let heading = displayedHeading else { return "--" }
        return CompassMath.direction(for: heading)
    }

    func update(heading: CLHeading) {
        magneticHeading = heading.magneticHeading >= 0 ? heading.magneticHeading : nil
        // trueHeading is negative when location is unavailable to compute declination.
        trueHeading = heading.trueHeading >= 0 ? heading.trueHeading : nil
        headingAccuracy = heading.headingAccuracy
        refreshSource()
    }

    func update(location: CLLocation) {
        let courseValid = location.course >= 0 && location.speed >= minimumCourseSpeedMps
            && (location.courseAccuracy < 0 || location.courseAccuracy <= 20)
        gpsCourse = courseValid ? location.course : nil
        refreshSource()
    }

    private func refreshSource() {
        if gpsCourse != nil && reference == .trueNorth {
            source = .gpsCourse
        } else if magneticHeading != nil {
            source = .magnetometer
        } else {
            source = .unavailable
        }
    }
}
