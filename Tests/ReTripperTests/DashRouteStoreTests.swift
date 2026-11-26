//
//  DashRouteStoreTests.swift
//  ReTripperTests
//
//  The shared store that hands the active route from the navigation engine
//  to the dash map renderer: set geometry, set the next turn, and clear.
//

import XCTest
import CoreLocation
@testable import ReTripper

final class DashRouteStoreTests: XCTestCase {

    override func tearDown() {
        DashRouteStore.shared.clear()
        super.tearDown()
    }

    func testStartsEmpty() {
        DashRouteStore.shared.clear()
        let snap = DashRouteStore.shared.snapshot
        XCTAssertFalse(snap.hasRoute)
        XCTAssertTrue(snap.coords.isEmpty)
        XCTAssertEqual(snap.maneuver, "")
    }

    func testRouteNeedsTwoPointsToCount() {
        DashRouteStore.shared.setRoute([CLLocationCoordinate2D(latitude: 1, longitude: 1)])
        XCTAssertFalse(DashRouteStore.shared.snapshot.hasRoute)

        DashRouteStore.shared.setRoute([
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
            CLLocationCoordinate2D(latitude: 2, longitude: 2),
        ])
        XCTAssertTrue(DashRouteStore.shared.snapshot.hasRoute)
    }

    func testManeuverIsStoredAndCleared() {
        DashRouteStore.shared.setRoute([
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
            CLLocationCoordinate2D(latitude: 2, longitude: 2),
        ])
        DashRouteStore.shared.setManeuver("TURN_LEFT", distance: 150)
        let snap = DashRouteStore.shared.snapshot
        XCTAssertEqual(snap.maneuver, "TURN_LEFT")
        XCTAssertEqual(snap.distanceToManeuver, 150, accuracy: 0.001)

        DashRouteStore.shared.clear()
        XCTAssertFalse(DashRouteStore.shared.snapshot.hasRoute)
        XCTAssertEqual(DashRouteStore.shared.snapshot.maneuver, "")
    }
}
