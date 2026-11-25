//
//  RouteTrackerTests.swift
//  ReTripperTests
//
//  Polyline decoding and live-guidance tracking (pure geometry).
//

import XCTest
import CoreLocation
@testable import ReTripper

final class EncodedPolylineTests: XCTestCase {
    func testDecodesGoogleReferenceExample() {
        // Google's documented example decodes to three points.
        let coords = EncodedPolyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(coords.count, 3)
        XCTAssertEqual(coords[0].latitude, 38.5, accuracy: 0.0001)
        XCTAssertEqual(coords[0].longitude, -120.2, accuracy: 0.0001)
        XCTAssertEqual(coords[2].latitude, 43.252, accuracy: 0.0001)
        XCTAssertEqual(coords[2].longitude, -126.453, accuracy: 0.0001)
    }

    func testEmptyStringDecodesToNothing() {
        XCTAssertTrue(EncodedPolyline.decode("").isEmpty)
    }
}

final class RouteTrackerTests: XCTestCase {

    // A ~222 m straight route running east along the equator, two steps.
    private func straightRoute() -> RouteTracker {
        let coords = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0.000),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.001),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.002),
        ]
        return RouteTracker(coords: coords,
                            stepDistances: [111, 111],
                            instructions: ["Turn right onto A St", "Turn left onto B Rd"],
                            maneuvers: ["TURN_RIGHT", "TURN_LEFT"],
                            totalDuration: 60)
    }

    func testAtStartFirstStepAndFullRemaining() {
        let snap = straightRoute().snapshot(for: .init(latitude: 0, longitude: 0))
        XCTAssertEqual(snap.stepIndex, 0)
        XCTAssertEqual(snap.instruction, "Turn right onto A St")
        XCTAssertEqual(snap.remainingDistance, 222, accuracy: 15)
        XCTAssertLessThan(snap.lateralOffset, 5)
        XCTAssertFalse(snap.arrived)
    }

    func testPastMidpointAdvancesToSecondStep() {
        let snap = straightRoute().snapshot(for: .init(latitude: 0, longitude: 0.0015))
        XCTAssertEqual(snap.stepIndex, 1)
        XCTAssertEqual(snap.instruction, "Turn left onto B Rd")
        XCTAssertLessThan(snap.remainingDistance, 120)
    }

    func testOffRouteProducesLargeLateralOffset() {
        // ~111 m north of the line.
        let snap = straightRoute().snapshot(for: .init(latitude: 0.001, longitude: 0.0005))
        XCTAssertGreaterThan(snap.lateralOffset, 45)
    }

    func testNearDestinationReportsArrived() {
        let snap = straightRoute().snapshot(for: .init(latitude: 0, longitude: 0.002))
        XCTAssertTrue(snap.arrived)
    }

    func testFailableInitRejectsDegenerateRoute() {
        let route = RouteResult(encodedPolyline: "", distanceMeters: 0, durationSeconds: 0, steps: [])
        XCTAssertNil(RouteTracker(route: route))
    }
}
