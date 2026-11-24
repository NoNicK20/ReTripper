//
//  DashboardPairingTests.swift
//  ReTripperTests
//
//  Reading the dash network name from camera text, Wi-Fi QR payloads,
//  and iOS hotspot error classification.
//

import XCTest
import NetworkExtension
@testable import ReTripper

final class DashboardPairingTextTests: XCTestCase {
    func testFindsNameShownOnGuerrillaDash() {
        XCTAssertEqual(DashboardPairingText.extractSSID(from: "RE_MVWW_260317"), "RE_MVWW_260317")
    }

    func testFindsNameInsideOtherRecognisedText() {
        let screen = "23:06 | 28°\nRE_MVWW_260317\nODO 3610 km"
        XCTAssertEqual(DashboardPairingText.extractSSID(from: screen), "RE_MVWW_260317")
    }

    func testRemovesSpacesOCRAddsAroundUnderscores() {
        XCTAssertEqual(DashboardPairingText.extractSSID(from: "RE _MVWW_ 260317"), "RE_MVWW_260317")
    }

    func testKeepsLetterCaseAsRead() {
        XCTAssertEqual(DashboardPairingText.extractSSID(from: "RE_MvWW_260317"), "RE_MvWW_260317")
    }

    func testIgnoresTextThatIsNotADashName() {
        XCTAssertNil(DashboardPairingText.extractSSID(from: "ODO 3610 km Side Stand"))
        XCTAssertNil(DashboardPairingText.extractSSID(from: "RE_"))
        XCTAssertNil(DashboardPairingText.extractSSID(from: "ROYAL ENFIELD"))
    }

    func testRejectsNamesLongerThanWiFiAllows() {
        let tooLong = "RE_" + String(repeating: "A", count: 40)
        XCTAssertNil(DashboardPairingText.extractSSID(from: tooLong))
    }

    func testParsesStandardWiFiQRCode() {
        let parsed = DashboardPairingText.parseWiFiPayload("WIFI:S:RE_ABC_123;T:WPA;P:secret99;;")
        XCTAssertEqual(parsed?.ssid, "RE_ABC_123")
        XCTAssertEqual(parsed?.password, "secret99")

        let open = DashboardPairingText.parseWiFiPayload("WIFI:S:RE_ABC_123;T:nopass;P:;;")
        XCTAssertEqual(open?.ssid, "RE_ABC_123")
        XCTAssertNil(open?.password)

        XCTAssertNil(DashboardPairingText.parseWiFiPayload("https://royalenfield.com"))
        XCTAssertNil(DashboardPairingText.parseWiFiPayload("WIFI:T:WPA;;"))
    }
}

final class DashboardWiFiTests: XCTestCase {
    func testTripperConstants() {
        XCTAssertEqual(DashboardWiFi.tripperPassphrase, "12345678")
        XCTAssertEqual(DashboardWiFi.gatewayIP, "192.168.1.1")
    }

    func testRecognisesTripperNetworks() {
        XCTAssertTrue(DashboardWiFi.looksLikeTripperSSID("RE_MVWW_260317"))
        XCTAssertTrue(DashboardWiFi.looksLikeTripperSSID("re_abc_123456"))
        XCTAssertFalse(DashboardWiFi.looksLikeTripperSSID("HomeWiFi"))
        XCTAssertFalse(DashboardWiFi.looksLikeTripperSSID("192.168.1.1"))
    }
}

final class HotspotApplyOutcomeTests: XCTestCase {
    func testErrorCodesMapToTheRightMeaning() {
        XCTAssertEqual(HotspotApplyOutcome.classify(code: NEHotspotConfigurationError.alreadyAssociated.rawValue),
                       .alreadyConnected)
        XCTAssertEqual(HotspotApplyOutcome.classify(code: NEHotspotConfigurationError.userDenied.rawValue),
                       .userDeclined)
        XCTAssertEqual(HotspotApplyOutcome.classify(code: NEHotspotConfigurationError.invalidWPAPassphrase.rawValue),
                       .badNameOrPassword)
        XCTAssertEqual(HotspotApplyOutcome.classify(code: NEHotspotConfigurationError.systemConfiguration.rawValue),
                       .notAllowedForThisBuild)
        XCTAssertEqual(HotspotApplyOutcome.classify(code: NEHotspotConfigurationError.applicationIsNotInForeground.rawValue),
                       .appNotInForeground)
        XCTAssertEqual(HotspotApplyOutcome.classify(code: 9_999), .otherFailure)
    }

    /// Regression: the old code treated error 8 ("internal") as "already connected",
    /// which could report a connection that never happened.
    func testInternalErrorIsNotTreatedAsConnected() {
        XCTAssertEqual(NEHotspotConfigurationError.internal.rawValue, 8)
        XCTAssertEqual(HotspotApplyOutcome.classify(code: 8), .otherFailure)
    }
}
