//
//  NavigationTests.swift
//  ReTripperTests
//
//  Google-driven navigation state, rerouting, maneuver parsing, shared links
//  and voice-guidance announcement planning.
//

import XCTest
import CoreLocation
@testable import ReTripper

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
                      remainingSeconds: 200, fractionComplete: 0.1)
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

/// Fake engine standing in for the Google Navigation SDK map.
@MainActor
final class FakeNavigationEngine: NavigationEngineControl {
    var isReady = true
    var notReadyReason = "Google Maps is not configured"
    var onUpdate: ((GoogleNavigationUpdate) -> Void)?
    var previewed: [[Destination]] = []
    var guidanceStarted = 0
    var guidanceStopped = 0

    func previewRoute(stops: [Destination]) { previewed.append(stops) }
    func startGuidance() { guidanceStarted += 1 }
    func stopGuidance() { guidanceStopped += 1 }

    func send(_ instruction: String?, step: Double = 300, remaining: Double = 2000, seconds: TimeInterval = 240,
              rerouting: Bool = false, arrived: Bool = false) {
        onUpdate?(GoogleNavigationUpdate(instruction: instruction, roadName: "MG Road", distanceToStepMeters: step,
                                         remainingMeters: remaining, remainingSeconds: seconds,
                                         isRerouting: rerouting, arrived: arrived, routeFailed: nil))
    }
}

@MainActor
final class FakePlaceSearch: PlaceSearchProvider {
    var finished = 0
    func suggestions(for query: String, near: CLLocationCoordinate2D?) async throws -> [Destination] {
        [Destination(name: query, subtitle: "Bengaluru", latitude: 0, longitude: 0, placeID: "place-" + query)]
    }
    func finishSession() { finished += 1 }
}

@MainActor
func makeNavigationManager(engine: FakeNavigationEngine = FakeNavigationEngine(),
                           search: FakePlaceSearch = FakePlaceSearch()) -> NavigationManager {
    let defaults = UserDefaults(suiteName: "nav-tests-" + UUID().uuidString)!
    return NavigationManager(engine: engine, search: search, store: DestinationStore(defaults: defaults))
}

@MainActor
final class NavigationManagerTests: XCTestCase {
    private let fort = Destination(name: "Fort", latitude: 0, longitude: 0, placeID: "fort")

    func testPreviewThenGuidanceStateMachine() {
        let engine = FakeNavigationEngine()
        let nav = makeNavigationManager(engine: engine)
        XCTAssertEqual(nav.status, .idle)
        nav.setDestination(fort)
        nav.previewRoute()
        XCTAssertEqual(nav.status, .calculating)
        XCTAssertEqual(engine.previewed.first?.first?.placeID, "fort")
        engine.onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false, routeFailed: nil, routeReady: true))
        XCTAssertEqual(nav.status, .preview)

        nav.startGuidance()
        XCTAssertEqual(nav.status, .navigating)
        XCTAssertEqual(engine.guidanceStarted, 1)
        engine.send("Turn right onto MG Road", step: 320, remaining: 2000)
        XCTAssertEqual(nav.progress?.nextManeuver, .right)
        XCTAssertEqual(nav.progress?.distanceToNextManeuverMeters, 320)
        engine.send("Turn right onto MG Road", step: 120, remaining: 1800)
        XCTAssertEqual(nav.progress?.fractionComplete ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(nav.progress?.stepIndex, 0)
        engine.send("Turn left", step: 500, remaining: 1700)
        XCTAssertEqual(nav.progress?.stepIndex, 1)

        nav.stopNavigation()
        XCTAssertEqual(nav.status, .idle)
        XCTAssertEqual(engine.guidanceStopped, 1)
        XCTAssertNil(nav.progress)
    }

    func testReroutingAndArrivalEvents() {
        let engine = FakeNavigationEngine()
        let nav = makeNavigationManager(engine: engine)
        var events: [NavigationEvent] = []
        let sub = nav.events.sink { events.append($0) }
        nav.setDestination(fort)
        nav.startGuidance()
        engine.send("Turn left")
        engine.send(nil, rerouting: true)
        XCTAssertEqual(nav.status, .rerouting)
        engine.send("Turn right")
        XCTAssertEqual(nav.status, .navigating)
        engine.send(nil, arrived: true)
        XCTAssertEqual(nav.status, .arrived)
        XCTAssertTrue(events.contains(.offRoute))
        XCTAssertTrue(events.contains(.rerouted))
        XCTAssertTrue(events.contains(.arrived("Fort")))
        sub.cancel()
    }

    func testNotConfiguredShowsMessageInsteadOfAnotherMap() {
        let engine = FakeNavigationEngine()
        engine.isReady = false
        let nav = makeNavigationManager(engine: engine)
        nav.setDestination(fort)
        nav.startGuidance()
        XCTAssertEqual(nav.status, .failed("Google Maps is not configured"))
        XCTAssertEqual(engine.guidanceStarted, 0)
    }

    func testRouteFailureReported() {
        let engine = FakeNavigationEngine()
        let nav = makeNavigationManager(engine: engine)
        nav.setDestination(fort)
        nav.previewRoute()
        engine.onUpdate?(GoogleNavigationUpdate(isRerouting: false, arrived: false, routeFailed: "No route"))
        XCTAssertEqual(nav.status, .failed("No route"))
    }

    func testWaypointsInsertedBeforeDestinationAndSessionsFinished() {
        let search = FakePlaceSearch()
        let nav = makeNavigationManager(search: search)
        nav.setDestination(fort)
        nav.addWaypoint(Destination(name: "Fuel", latitude: 1, longitude: 1))
        XCTAssertEqual(nav.stops.map { $0.name }, ["Fuel", "Fort"])
        XCTAssertEqual(search.finished, 2)
        nav.removeStop(at: 0)
        XCTAssertEqual(nav.stops.map { $0.name }, ["Fort"])
    }

    func testSearchUsesPlacesAndRecognisesSharedLinks() async {
        let nav = makeNavigationManager()
        let places = await nav.search("Cubbon Park", near: nil)
        XCTAssertEqual(places.first?.placeID, "place-Cubbon Park")
        let link = await nav.search("geo:12.5,77.5", near: nil)
        XCTAssertEqual(link.first?.latitude ?? 0, 12.5, accuracy: 0.0001)
    }

    func testPlaceIDIdentity() {
        let a = Destination(name: "A", latitude: 0, longitude: 0, placeID: "x")
        let b = Destination(name: "B", latitude: 0, longitude: 0, placeID: "x")
        let c = Destination(name: "C", latitude: 0, longitude: 0, placeID: "y")
        XCTAssertTrue(a.isSamePlace(as: b))
        XCTAssertFalse(a.isSamePlace(as: c))
    }
}
