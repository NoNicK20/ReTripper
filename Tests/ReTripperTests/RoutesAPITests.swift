//
//  RoutesAPITests.swift
//  ReTripperTests
//
//  Parsing and error-message mapping for the self-serve Routes API client.
//  The live HTTP call can only be exercised on a device with a key; the JSON
//  decoding and failure messages are pure and tested here.
//

import XCTest
import CoreLocation
@testable import ReTripper

final class RoutesAPIParsingTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesRouteTotalsPolylineAndSteps() throws {
        let json = """
        {
          "routes": [{
            "distanceMeters": 12000,
            "duration": "1500s",
            "polyline": { "encodedPolyline": "_p~iF~ps|U_ulLnnqC" },
            "legs": [{ "steps": [
              { "navigationInstruction": { "maneuver": "TURN_RIGHT", "instructions": "Turn right onto MG Road" },
                "distanceMeters": 300, "polyline": { "encodedPolyline": "abc" } },
              { "navigationInstruction": { "maneuver": "TURN_LEFT", "instructions": "Turn left" },
                "distanceMeters": 500 }
            ]}]
          }]
        }
        """
        let result = try RoutesAPIClient.parse(data(json))
        XCTAssertEqual(result.encodedPolyline, "_p~iF~ps|U_ulLnnqC")
        XCTAssertEqual(result.distanceMeters, 12000, accuracy: 0.001)
        XCTAssertEqual(result.durationSeconds, 1500, accuracy: 0.001)
        XCTAssertEqual(result.steps.count, 2)
        let firstStep = try XCTUnwrap(result.steps.first)
        XCTAssertEqual(firstStep.maneuver, "TURN_RIGHT")
        XCTAssertTrue(firstStep.instruction.contains("MG Road"))
        XCTAssertEqual(firstStep.distanceMeters, 300, accuracy: 0.001)
    }

    func testEmptyRoutesThrowsNoRoute() {
        XCTAssertThrowsError(try RoutesAPIClient.parse(data(#"{ "routes": [] }"#))) { error in
            XCTAssertEqual(error as? RoutesAPIError, .noRoute)
        }
    }

    func testMissingPolylineThrowsDecode() {
        let json = #"{ "routes": [{ "distanceMeters": 10 }] }"#
        XCTAssertThrowsError(try RoutesAPIClient.parse(data(json))) { error in
            XCTAssertEqual(error as? RoutesAPIError, .decode)
        }
    }

    func testWaypointUsesPlaceIDWhenPresent() {
        let wp = RoutesAPIClient.Waypoint(coordinate: .init(latitude: 1, longitude: 2), placeID: "place-123")
        let json = RoutesAPIClient.waypointJSON(wp)
        XCTAssertEqual(json["placeId"] as? String, "place-123")
        XCTAssertNil(json["location"])
    }

    func testWaypointFallsBackToLatLng() {
        let wp = RoutesAPIClient.Waypoint(coordinate: .init(latitude: 12.97, longitude: 77.59), placeID: nil)
        let json = RoutesAPIClient.waypointJSON(wp)
        let latLng = (json["location"] as? [String: Any])?["latLng"] as? [String: Any]
        XCTAssertEqual(latLng?["latitude"] as? Double, 12.97)
        XCTAssertEqual(latLng?["longitude"] as? Double, 77.59)
    }

    func testHTTP403MessagesAreActionable() {
        let disabled = RoutesAPIError.describeHTTP(code: 403,
            googleMessage: "Routes API has not been used in project 1 before or it is disabled.")
        XCTAssertTrue(disabled.localizedCaseInsensitiveContains("enable"), disabled)

        let restricted = RoutesAPIError.describeHTTP(code: 403,
            googleMessage: "Requests to this API are blocked due to the key restriction.")
        XCTAssertTrue(restricted.localizedCaseInsensitiveContains("allowed APIs")
                      || restricted.localizedCaseInsensitiveContains("restrict"), restricted)
    }
}
