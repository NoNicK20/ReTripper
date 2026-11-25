//
//  DashMapTests.swift
//  ReTripperTests
//
//  Web Mercator tile math for the Google Map Tiles renderer. The live tile
//  fetch / compositing can only be verified on a device with a key.
//

import XCTest
import CoreLocation
@testable import ReTripper

final class WebMercatorTests: XCTestCase {

    func testWorldPixelCentreAtZoomZero() {
        let p = WebMercator.worldPixel(CLLocationCoordinate2D(latitude: 0, longitude: 0), zoom: 0)
        XCTAssertEqual(p.x, 128, accuracy: 0.001)
        XCTAssertEqual(p.y, 128, accuracy: 0.001)
    }

    func testLongitudeMapsLinearly() {
        let east = WebMercator.worldPixel(CLLocationCoordinate2D(latitude: 0, longitude: 180), zoom: 0)
        XCTAssertEqual(east.x, 256, accuracy: 0.001)
        let west = WebMercator.worldPixel(CLLocationCoordinate2D(latitude: 0, longitude: -180), zoom: 0)
        XCTAssertEqual(west.x, 0, accuracy: 0.001)
    }

    func testTileIndex() {
        let a = WebMercator.tileIndex(CLLocationCoordinate2D(latitude: 0, longitude: 0), zoom: 0)
        XCTAssertEqual(a.x, 0); XCTAssertEqual(a.y, 0)
        let b = WebMercator.tileIndex(CLLocationCoordinate2D(latitude: 0, longitude: 0), zoom: 2)
        XCTAssertEqual(b.x, 2); XCTAssertEqual(b.y, 2)
    }

    func testTileWrapAndClamp() {
        let w1 = WebMercator.wrap(x: -1, y: 0, zoom: 1)
        XCTAssertEqual(w1?.x, 1); XCTAssertEqual(w1?.y, 0)   // x wraps
        let w2 = WebMercator.wrap(x: 2, y: 1, zoom: 1)
        XCTAssertEqual(w2?.x, 0); XCTAssertEqual(w2?.y, 1)   // x wraps
        XCTAssertNil(WebMercator.wrap(x: 0, y: 2, zoom: 1))  // y out of range
        XCTAssertNil(WebMercator.wrap(x: 0, y: -1, zoom: 1))
    }

    func testLatitudeClampsToMercatorLimit() {
        // Latitudes past the Mercator limit clamp to the top edge (y ≈ 0),
        // allowing for floating-point rounding around zero.
        let north = WebMercator.worldPixel(CLLocationCoordinate2D(latitude: 89, longitude: 0), zoom: 0)
        XCTAssertEqual(north.y, 0, accuracy: 0.01)
        let south = WebMercator.worldPixel(CLLocationCoordinate2D(latitude: -89, longitude: 0), zoom: 0)
        XCTAssertEqual(south.y, 256, accuracy: 0.01)
    }
}

final class GoogleTileFailureMessageTests: XCTestCase {

    private func message(_ status: Int?, _ googleMessage: String? = nil) -> String {
        var json: [String: Any]? = nil
        if let googleMessage { json = ["error": ["message": googleMessage]] }
        return GoogleTileFetcher.describeFailure(status: status, json: json)
    }

    func test403DisabledApiIsExplained() {
        let m = message(403, "Map Tiles API has not been used in project 123 before or it is disabled.")
        XCTAssertTrue(m.localizedCaseInsensitiveContains("not enabled"), m)
    }

    func test403KeyRestrictionIsExplained() {
        let m = message(403, "Requests to this API are blocked due to the API key restriction.")
        XCTAssertTrue(m.localizedCaseInsensitiveContains("restricted"), m)
    }

    func test403GenericStillMentionsRestrictions() {
        let m = message(403)
        XCTAssertTrue(m.contains("403"), m)
    }

    func testQuotaAndNoResponse() {
        XCTAssertTrue(message(429).contains("429"))
        XCTAssertTrue(message(nil).localizedCaseInsensitiveContains("no response"))
    }
}
