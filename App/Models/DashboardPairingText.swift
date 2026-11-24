//
//  DashboardPairingText.swift
//  ReTripper
//
//  Pure helpers for Tripper Dash pairing:
//  - finding the dash's Wi-Fi network name in camera-recognised text
//    (the dash shows e.g. "RE_MVWW_260317" after holding the joystick for 3 s;
//    it does not show a QR code),
//  - parsing standard "WIFI:" QR payloads,
//  - classifying iOS hotspot-configuration errors.
//

import Foundation
import NetworkExtension

/// Fixed facts about the Royal Enfield Tripper Dash Wi-Fi access point.
///
/// These are the same on every bike and are documented by the open-source
/// Tripper community (e.g. TripperDash++). They are NOT a per-rider secret or
/// an API key: every dash ships with the identical passphrase, so this is an
/// interoperability constant, like the fixed gateway address, not a credential
/// to protect. The rider can still override the password in the UI if their
/// dash was set to a custom one.
enum DashboardWiFi {
    /// The WPA2 passphrase every Tripper Dash AP ships with.
    static let tripperPassphrase = "12345678"

    /// The dash's fixed gateway / IP address on its own Wi-Fi.
    static let gatewayIP = "192.168.1.1"

    /// Whether an SSID looks like a Tripper Dash network (so the standard
    /// passphrase should be used). Accepts the exact `RE_XXXX_XXXXXX` form and,
    /// more leniently, any `RE_` network.
    static func looksLikeTripperSSID(_ ssid: String) -> Bool {
        ssid.uppercased().hasPrefix("RE_")
    }
}

enum DashboardPairingText {
    /// Royal Enfield dash network names start with "RE_" followed by letters/digits,
    /// separated by underscores (seen on a Guerrilla 450: "RE_MVWW_260317").
    private static let ssidPattern = "RE_[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*"

    /// Returns the first plausible dash network name in recognised text, or nil.
    /// Spaces that OCR sometimes inserts around underscores are removed.
    /// The case of the letters is kept exactly as read; the user confirms it before joining.
    static func extractSSID(from recognised: String) -> String? {
        let compact = recognised
            .replacingOccurrences(of: "\\s*_\\s*", with: "_", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: ssidPattern) else { return nil }
        let range = NSRange(compact.startIndex..., in: compact)
        for match in regex.matches(in: compact, range: range) {
            guard let r = Range(match.range, in: compact) else { continue }
            let candidate = String(compact[r])
            // At least one block after "RE_", and within the 32-byte SSID limit.
            if candidate.count >= 6, candidate.utf8.count <= 32 {
                return candidate
            }
        }
        return nil
    }

    /// Parses a standard Wi-Fi QR payload ("WIFI:S:<ssid>;T:WPA;P:<password>;;").
    /// Returns nil for anything else.
    static func parseWiFiPayload(_ payload: String) -> (ssid: String, password: String?)? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("WIFI:") else { return nil }
        var ssid: String?
        var password: String?
        for field in trimmed.dropFirst(5).components(separatedBy: ";") {
            if field.hasPrefix("S:") || field.hasPrefix("s:") {
                ssid = String(field.dropFirst(2))
            } else if field.hasPrefix("P:") || field.hasPrefix("p:") {
                let value = String(field.dropFirst(2))
                password = value.isEmpty ? nil : value
            }
        }
        guard let name = ssid, !name.isEmpty, name.utf8.count <= 32 else { return nil }
        return (name, password)
    }
}

/// What an `NEHotspotConfigurationManager.apply` error means for the user.
enum HotspotApplyOutcome: Equatable {
    case alreadyConnected
    case userDeclined
    case badNameOrPassword
    case notAllowedForThisBuild
    case appNotInForeground
    case otherFailure
}

extension HotspotApplyOutcome {
    /// Maps an error code in `NEHotspotConfigurationErrorDomain` to an outcome.
    static func classify(code: Int) -> HotspotApplyOutcome {
        guard let error = NEHotspotConfigurationError(rawValue: code) else { return .otherFailure }
        switch error {
        case .alreadyAssociated:
            return .alreadyConnected
        case .userDenied:
            return .userDeclined
        case .invalid, .invalidSSID, .invalidWPAPassphrase, .invalidWEPPassphrase:
            return .badNameOrPassword
        case .systemConfiguration:
            return .notAllowedForThisBuild
        case .applicationIsNotInForeground:
            return .appNotInForeground
        default:
            return .otherFailure
        }
    }
}
