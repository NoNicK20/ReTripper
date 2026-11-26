//
//  FuelMileage.swift
//  ReTripper
//
//  Tank-to-tank fuel economy from refuel logs, plus the two-way fill maths
//  (litres ⇄ total cost). Pure functions, so the arithmetic is unit-testable
//  without any UI.
//

import Foundation

/// Tank-to-tank fuel economy from refuel logs.
enum FuelMileage {

    /// One computed interval between two consecutive full-tank fills.
    struct Interval: Equatable {
        /// The later (closing) full-tank fill this economy belongs to.
        let fillID: UUID
        /// Distance covered over the interval, in the app's distance unit.
        let distance: Double
        /// Fuel burned over the interval, in litres.
        let liters: Double
        /// Distance per litre (e.g. km/L).
        var economy: Double { liters > 0 ? distance / liters : 0 }
    }

    /// Tank-to-tank intervals in chronological (odometer) order.
    ///
    /// Full-tank fills act as anchors. The distance between two consecutive
    /// full tanks is divided by every litre added after the first anchor up to
    /// and including the closing fill, so partial fills in between are counted.
    static func intervals(from logs: [FuelLog]) -> [Interval] {
        let ordered = logs.sorted {
            if $0.odometer != $1.odometer { return $0.odometer < $1.odometer }
            return $0.date < $1.date
        }
        var result: [Interval] = []
        var anchorOdo: Double? = nil
        var litersSinceAnchor = 0.0
        for log in ordered {
            if anchorOdo != nil { litersSinceAnchor += log.liters }
            if log.isFullTank {
                if let start = anchorOdo {
                    let distance = log.odometer - start
                    if distance > 0 && litersSinceAnchor > 0 {
                        result.append(Interval(fillID: log.id, distance: distance, liters: litersSinceAnchor))
                    }
                }
                anchorOdo = log.odometer
                litersSinceAnchor = 0
            }
        }
        return result
    }

    /// The most recent completed tank-to-tank interval, if any.
    static func latest(from logs: [FuelLog]) -> Interval? { intervals(from: logs).last }

    /// Lifetime average economy: total distance across all full-to-full
    /// intervals divided by total litres across them.
    static func average(from logs: [FuelLog]) -> Double? {
        let ivals = intervals(from: logs)
        guard !ivals.isEmpty else { return nil }
        let dist = ivals.reduce(0) { $0 + $1.distance }
        let lit = ivals.reduce(0) { $0 + $1.liters }
        return lit > 0 ? dist / lit : nil
    }
}

/// The two-way maths behind the fill form: fix any two of
/// (litres, price per litre, total cost) and the third follows.
enum FuelEntryMath {
    /// Total cost from litres and price per litre.
    static func totalCost(liters: Double, pricePerLiter: Double) -> Double {
        liters * pricePerLiter
    }

    /// Litres from total cost and price per litre (0 when price is non-positive).
    static func liters(totalCost: Double, pricePerLiter: Double) -> Double {
        pricePerLiter > 0 ? totalCost / pricePerLiter : 0
    }
}
