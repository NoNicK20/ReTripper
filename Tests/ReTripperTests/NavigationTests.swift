//
//  NavigationTests.swift
//  ReTripperTests
//
//  Route progress, deviation/rerouting, maneuver parsing, shared links
//  and voice-guidance announcement planning.
//

import XCTest
import CoreLocation
@testable import ReTripper

/// Straight north-bound test route: two steps of ~555 m each.
private func makeRoute(stops: [Destination]? = nil) -> NavRoute {
    let a = (0...5).map { CLLocationCoordinate2D(latitude: 12.0 + Double($0) * 0.001, longitude: 77.0) }
    let b = (5...10).map { CLLocationCoordinate2D(latitude: 12.0 + Double($0) * 0.001, longitude: 77.0) }
    let dest = Destination(name: "Fort", latitude: 12.010, longitude: 77.0)
    return NavRoute(name: "Test", distanceMeters: 1106, expectedTravelSeconds: 110,
                    steps: [NavStep(instruction: "Head north", maneuver: .depart, roadName: nil, distanceMeters: 553, coordinates: a),
                            NavStep(instruction: "Turn right onto MG Road", maneuver: .right, roadName: "MG Road", distanceMeters: 553, coordinates: b)],
                    stops: stops ?? [dest], sourceLabel: "Test")
}

final class RouteProgressTrackerTests: XCTestCase {
    func testProgressAlongRoute() {
        var tracker = RouteProgressTracker(route: makeRoute())
        guard case .onRoute(let p) = tracker.update(with: CLLocationCoordinate2D(latitude: 12.002, longitude: 77.0)) else {
            return XCTFail("Expected on-route")
        }
        XCTAssertEqual(p.stepIndex, 0)
        XCTAssertEqual(p.nextManeuver, .right)
        XCTAssertEqual(p.nextRoadName, "MG Road")
        XCTAssertEqual(p.distanceToNextManeuverMeters, 332, accuracy: 10)
        XCTAssertEqual(p.remainingDistanceMeters, 885, accuracy: 15)
        XCTAssertEqual(p.fractionComplete, 0.2, accuracy: 0.02)
    }

    func testOffRouteRequiresConsecutiveSamples() {
        var tracker = RouteProgressTracker(route: makeRoute())
        let far = CLLocationCoordinate2D(latitude: 12.003, longitude: 77.003) // ~325 m east
        if case .offRoute = tracker.update(with: far) { XCTFail("Too early") }
        if case .offRoute = tracker.update(with: far) { XCTFail("Too early") }
        guard case .offRoute(let d) = tracker.update(with: far) else { return XCTFail("Expected off-route") }
        XCTAssertGreaterThan(d, 250)
        // A good sample resets the counter.
        _ = tracker.update(with: CLLocationCoordinate2D(latitude: 12.004, longitude: 77.0))
        XCTAssertEqual(tracker.offRouteCount, 0)
    }

    func testArrival() {
        var tracker = RouteProgressTracker(route: makeRoute())
        XCTAssertEqual(tracker.update(with: CLLocationCoordinate2D(latitude: 12.00999, longitude: 77.0)), .arrived)
    }
}

final class ParsingTests: XCTestCase {
    func testManeuverParsing() {
        XCTAssertEqual(Maneuver.parse(instruction: "Turn left onto Residency Rd"), .left)
        XCTAssertEqual(Maneuver.parse(instruction: "Turn right"), .right)
        XCTAssertEqual(Maneuver.parse(instruction: "Keep left at the fork"), .keepLeft)
        XCTAssertEqual(Maneuver.parse(instruction: "Take a slight right"), .slightRight)
        XCTAssertEqual(Maneuver.parse(instruction: "At the roundabout, take the 2nd exit"), .roundabout)
        XCTAssertEqual(Maneuver.parse(instruction: "Make a U-turn"), .uTurn)
        XCTAssertEqual(Maneuver.parse(instruction: "Arrive at the destination"), .arrive)
        XCTAssertEqual(Maneuver.roadName(from: "Turn right onto MG Road"), "MG Road")
        XCTAssertNil(Maneuver.roadName(from: "Continue"))
    }

    func testSharedLinkParsing() {
        let custom = DestinationLinkParser.parse("retripper://navigate?lat=12.97&lon=77.59&name=Cubbon%20Park")
        XCTAssertEqual(custom?.name, "Cubbon Park")
        XCTAssertEqual(custom?.latitude ?? 0, 12.97, accuracy: 0.0001)

        let google = DestinationLinkParser.parse("https://www.google.com/maps?q=12.9716,77.5946")
        XCTAssertEqual(google?.longitude ?? 0, 77.5946, accuracy: 0.0001)

        let googleAt = DestinationLinkParser.parse("https://www.google.com/maps/place/Somewhere/@12.5,77.25,15z")
        XCTAssertEqual(googleAt?.latitude ?? 0, 12.5, accuracy: 0.0001)

        let apple = DestinationLinkParser.parse("https://maps.apple.com/?ll=12.1,77.2&q=Fort")
        XCTAssertEqual(apple?.name, "Fort")

        XCTAssertNotNil(DestinationLinkParser.parse("geo:12.1,77.2"))
        XCTAssertNil(DestinationLinkParser.parse("https://example.com/?q=12,77"))
        XCTAssertNil(DestinationLinkParser.parse("retripper://navigate?lat=200&lon=77"))
        XCTAssertNil(DestinationLinkParser.parse("Coffee near me"))
    }
}

final class GuidancePlannerTests: XCTestCase {
    private func progress(_ distance: Double, maneuver: Maneuver = .right, step: Int = 0) -> RouteProgress {
        RouteProgress(stepIndex: step, nextManeuver: maneuver, nextInstruction: "Turn right onto MG Road",
                      nextRoadName: "MG Road", distanceToNextManeuverMeters: distance, remainingDistanceMeters: 2000,
                      remainingSeconds: 200, fractionComplete: 0.1, distanceFromRouteMeters: 3)
    }

    func testPrepareAndImminentAnnouncedOnceEach() {
        var planner = GuidanceAnnouncementPlanner()
        XCTAssertNil(planner.announcement(for: progress(900), mode: .full, speedMps: 10))
        XCTAssertEqual(planner.announcement(for: progress(300), mode: .full, speedMps: 10),
                       "In 300 meters, turn right onto MG Road")
        XCTAssertNil(planner.announcement(for: progress(250), mode: .full, speedMps: 10))
        XCTAssertEqual(planner.announcement(for: progress(50), mode: .full, speedMps: 10), "Turn right onto MG Road")
        XCTAssertNil(planner.announcement(for: progress(30), mode: .full, speedMps: 10))
        // A new step is announced again.
        XCTAssertNotNil(planner.announcement(for: progress(50, step: 1), mode: .full, speedMps: 10))
    }

    func testImportantOnlyAndMuted() {
        var planner = GuidanceAnnouncementPlanner()
        XCTAssertNil(planner.announcement(for: progress(300), mode: .importantOnly, speedMps: 10))
        XCTAssertNil(planner.announcement(for: progress(50, maneuver: .straight), mode: .importantOnly, speedMps: 10))
        XCTAssertNotNil(planner.announcement(for: progress(50), mode: .importantOnly, speedMps: 10))
        var muted = GuidanceAnnouncementPlanner()
        XCTAssertNil(muted.announcement(for: progress(50), mode: .muted, speedMps: 10))
    }

    func testSpokenDistance() {
        XCTAssertEqual(GuidanceAnnouncementPlanner.spokenDistance(1500), "1.5 kilometers")
        XCTAssertEqual(GuidanceAnnouncementPlanner.spokenDistance(2000), "2 kilometers")
        XCTAssertEqual(GuidanceAnnouncementPlanner.spokenDistance(320), "300 meters")
    }
}

/// Fake provider so navigation state can be tested without network access.
final class FakeRouteProvider: NavigationRouteProvider {
    let engine: NavigationEngine = .appleMapKit
    var routeCalls = 0
    var routesToReturn: [NavRoute] = [makeRoute(), makeRoute()]

    func searchDestinations(query: String, near: CLLocationCoordinate2D?) async throws -> [Destination] {
        [Destination(name: query, latitude: 12, longitude: 77)]
    }

    func calculateRoutes(from origin: CLLocationCoordinate2D, stops: [Destination]) async throws -> [NavRoute] {
        routeCalls += 1
        return routesToReturn
    }
}

@MainActor
final class NavigationManagerTests: XCTestCase {
    private func loc(_ lat: Double, _ lon: Double = 77.0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                   horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
    }

    func testRoutePreviewAlternativesAndGuidanceStates() async {
        let provider = FakeRouteProvider()
        let nav = NavigationManager(provider: provider)
        XCTAssertEqual(nav.status, .idle)
        nav.stops = [Destination(name: "Fort", latitude: 12.01, longitude: 77)]
        await nav.calculateRoutes(from: CLLocationCoordinate2D(latitude: 12, longitude: 77))
        XCTAssertEqual(nav.status, .preview)
        XCTAssertEqual(nav.candidateRoutes.count, 2)
        nav.selectedRouteIndex = 1
        nav.startGuidance()
        XCTAssertEqual(nav.status, .navigating)
        XCTAssertEqual(nav.activeRoute, nav.candidateRoutes[1])

        nav.update(location: loc(12.002))
        XCTAssertEqual(nav.progress?.nextManeuver, .right)

        nav.stopNavigation()
        XCTAssertEqual(nav.status, .idle)
        XCTAssertNil(nav.progress)
    }

    func testDeviationTriggersReroute() async throws {
        let provider = FakeRouteProvider()
        let nav = NavigationManager(provider: provider)
        nav.stops = [Destination(name: "Fort", latitude: 12.01, longitude: 77)]
        await nav.calculateRoutes(from: CLLocationCoordinate2D(latitude: 12, longitude: 77))
        nav.startGuidance()
        XCTAssertEqual(provider.routeCalls, 1)
        for _ in 0..<3 { nav.update(location: loc(12.003, 77.003)) }
        XCTAssertEqual(nav.status, .rerouting)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(provider.routeCalls, 2)
        XCTAssertEqual(nav.status, .navigating)
    }

    func testArrivalEndsGuidance() async {
        let nav = NavigationManager(provider: FakeRouteProvider())
        nav.stops = [Destination(name: "Fort", latitude: 12.01, longitude: 77)]
        await nav.calculateRoutes(from: CLLocationCoordinate2D(latitude: 12, longitude: 77))
        nav.startGuidance()
        nav.update(location: loc(12.00999))
        XCTAssertEqual(nav.status, .arrived)
    }

    func testSearchRecognisesSharedLinks() async {
        let nav = NavigationManager(provider: FakeRouteProvider())
        let results = await nav.search("geo:12.5,77.5", near: nil)
        XCTAssertEqual(results.first?.latitude ?? 0, 12.5, accuracy: 0.0001)
    }
}
