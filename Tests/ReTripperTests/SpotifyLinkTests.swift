//
//  SpotifyLinkTests.swift
//  ReTripperTests
//
//  The Spotify authorization redirect must be recognised (and distinguished
//  from the app's other retripper:// links) so the App Remote connection
//  completes and ordinary shared-destination links still route as before.
//

import XCTest
@testable import ReTripper

@MainActor
final class SpotifyLinkTests: XCTestCase {

    func testRecognisesSpotifyCallback() {
        XCTAssertTrue(MusicManager.isSpotifyCallback(URL(string: "retripper://spotify-callback")!))
        XCTAssertTrue(MusicManager.isSpotifyCallback(URL(string: "retripper://spotify-callback?code=abc&state=1")!))
    }

    func testIgnoresOtherRetripperLinks() {
        XCTAssertFalse(MusicManager.isSpotifyCallback(URL(string: "retripper://navigate?lat=12.97&lon=77.59")!))
        XCTAssertFalse(MusicManager.isSpotifyCallback(URL(string: "retripper://spotify-callbackx")!))
    }

    func testIgnoresForeignSchemes() {
        XCTAssertFalse(MusicManager.isSpotifyCallback(URL(string: "https://spotify-callback")!))
        XCTAssertFalse(MusicManager.isSpotifyCallback(URL(string: "spotify://spotify-callback")!))
    }
}
