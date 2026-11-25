//
//  RouteTracker.swift
//  ReTripper
//
//  Turns a computed route plus the rider's live position into a navigation
//  snapshot: which maneuver is next, how far to it, distance/time remaining,
//  how far off the route the rider is (for rerouting), and whether they've
//  arrived. Pure geometry (no CoreLocation services), so it is unit-testable.
//

import CoreLocation
import Foundation

struct RouteTracker {

    let coords: [CLLocationCoordinate2D]
    let cumulative: [CLLocationDistance]   // distance along the route at each coord
    let totalDistance: CLLocationDistance
    let totalDuration: TimeInterval
    let stepEnds: [CLLocationDistance]     // distance-along at the end of each step
    let instructions: [String]
    let maneuvers: [String]

    struct Snapshot {
        let stepIndex: Int
        let instruction: String
        let maneuver: String
        let distanceToManeuver: CLLocationDistance
        let remainingDistance: CLLocationDistance
        let remainingDuration: TimeInterval
        let lateralOffset: CLLocationDistance   // how far the rider is from the line
        let arrived: Bool
    }

    init(coords: [CLLocationCoordinate2D],
         stepDistances: [CLLocationDistance],
         instructions: [String],
         maneuvers: [String],
         totalDuration: TimeInterval) {
        self.coords = coords
        var cum: [CLLocationDistance] = coords.isEmpty ? [] : [0]
        if coords.count >= 2 {
            for i in 1..<coords.count {
                cum.append(cum[i - 1] + Self.distance(coords[i - 1], coords[i]))
            }
        }
        self.cumulative = cum
        self.totalDistance = cum.last ?? 0
        var ends: [CLLocationDistance] = []
        var running: CLLocationDistance = 0
        for d in stepDistances { running += d; ends.append(running) }
        self.stepEnds = ends
        self.instructions = instructions
        self.maneuvers = maneuvers
        self.totalDuration = totalDuration
    }

    init?(route: RouteResult) {
        let coords = EncodedPolyline.decode(route.encodedPolyline)
        guard coords.count >= 2 else { return nil }
        self.init(coords: coords,
                  stepDistances: route.steps.map { $0.distanceMeters },
                  instructions: route.steps.map { $0.instruction },
                  maneuvers: route.steps.map { $0.maneuver },
                  totalDuration: route.durationSeconds)
    }

    func snapshot(for rider: CLLocationCoordinate2D) -> Snapshot {
        guard coords.count >= 2 else {
            return Snapshot(stepIndex: 0, instruction: instructions.first ?? "",
                            maneuver: maneuvers.first ?? "", distanceToManeuver: 0,
                            remainingDistance: 0, remainingDuration: 0, lateralOffset: 0, arrived: true)
        }

        // Project the rider onto the nearest segment to find how far along the
        // route they are (and how far off it, laterally).
        var bestAlong: CLLocationDistance = 0
        var bestLateral = CLLocationDistance.greatestFiniteMagnitude
        for i in 0..<(coords.count - 1) {
            let (proj, t) = Self.project(rider, coords[i], coords[i + 1])
            let lateral = Self.distance(rider, proj)
            if lateral < bestLateral {
                bestLateral = lateral
                bestAlong = cumulative[i] + t * (cumulative[i + 1] - cumulative[i])
            }
        }

        let remaining = max(0, totalDistance - bestAlong)
        let remainingDuration = totalDistance > 0 ? totalDuration * (remaining / totalDistance) : 0

        var stepIndex = 0
        var maneuverEnd = totalDistance
        if !stepEnds.isEmpty {
            stepIndex = stepEnds.firstIndex(where: { $0 > bestAlong + 1 }) ?? (stepEnds.count - 1)
            maneuverEnd = stepEnds[min(stepIndex, stepEnds.count - 1)]
        }
        let distanceToManeuver = max(0, maneuverEnd - bestAlong)

        return Snapshot(
            stepIndex: stepIndex,
            instruction: instructions[safe: stepIndex] ?? "",
            maneuver: maneuvers[safe: stepIndex] ?? "",
            distanceToManeuver: distanceToManeuver,
            remainingDistance: remaining,
            remainingDuration: remainingDuration,
            lateralOffset: bestLateral,
            arrived: remaining < 20)
    }

    // MARK: - Geometry

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180
        let la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Projects `p` onto segment `a`→`b` using a local flat approximation.
    /// Returns the projected coordinate and the clamped fraction `t` in [0, 1].
    static func project(_ p: CLLocationCoordinate2D,
                        _ a: CLLocationCoordinate2D,
                        _ b: CLLocationCoordinate2D) -> (CLLocationCoordinate2D, Double) {
        let mPerDegLat = 111_320.0
        let mPerDegLng = 111_320.0 * cos(a.latitude * .pi / 180)
        let px = (p.longitude - a.longitude) * mPerDegLng
        let py = (p.latitude - a.latitude) * mPerDegLat
        let bx = (b.longitude - a.longitude) * mPerDegLng
        let by = (b.latitude - a.latitude) * mPerDegLat
        let len2 = bx * bx + by * by
        var t = len2 > 0 ? (px * bx + py * by) / len2 : 0
        t = max(0, min(1, t))
        let projLat = a.latitude + t * (b.latitude - a.latitude)
        let projLng = a.longitude + t * (b.longitude - a.longitude)
        return (CLLocationCoordinate2D(latitude: projLat, longitude: projLng), t)
    }
}
