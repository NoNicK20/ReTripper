//
//  DashRouteStore.swift
//  ReTripper
//
//  Carries the active navigation route from the navigation engine (main
//  actor) to the dash map frame renderer (its own render thread). Plain
//  NSLock, no actor isolation, so either side can read or write it safely.
//
//  Only the geometry and the next maneuver are shared — the dash map draws
//  the route line and a turn banner from this; it never drives the bike.
//

import CoreLocation
import Foundation

final class DashRouteStore: @unchecked Sendable {
    static let shared = DashRouteStore()

    struct Snapshot {
        var coords: [CLLocationCoordinate2D] = []
        /// Google maneuver token for the next turn, e.g. "TURN_LEFT".
        var maneuver: String = ""
        /// Metres to the next maneuver.
        var distanceToManeuver: Double = 0
        var hasRoute: Bool { coords.count >= 2 }
    }

    private let lock = NSLock()
    private var stored = Snapshot()

    /// A copy of the current route snapshot (safe to read from any thread).
    var snapshot: Snapshot { lock.withLock { stored } }

    /// Replace the route geometry. Keeps the last maneuver until the next fix.
    func setRoute(_ coords: [CLLocationCoordinate2D]) {
        lock.withLock { stored.coords = coords }
    }

    /// Update the next-turn banner shown on the dash.
    func setManeuver(_ maneuver: String, distance: Double) {
        lock.withLock {
            stored.maneuver = maneuver
            stored.distanceToManeuver = distance
        }
    }

    /// No active route — the dash map drops back to a plain moving map.
    func clear() {
        lock.withLock { stored = Snapshot() }
    }
}

/// Dash map display preferences kept in UserDefaults so both the SwiftUI
/// settings toggle and the (non-main-actor) frame renderer can read them
/// without crossing actor isolation.
enum DashMapDefaults {
    static let headingUpKey = "retripper_dash_map_heading_up"
    /// Heading-up (map rotates to travel direction) when true; north-up
    /// (fixed, readable labels) when false — the default.
    static var headingUp: Bool { UserDefaults.standard.bool(forKey: headingUpKey) }
}
