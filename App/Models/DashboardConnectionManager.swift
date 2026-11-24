//
//  DashboardConnectionManager.swift
//  ReTripper
//
//  Manages Wi-Fi association and Tripper Dash session state.
//  Supports three entry points:
//  1. Manual SSID Entry (P0)
//  2. Scan Dashboard QR Code
//  3. Existing Wi-Fi Connection via iOS Settings
//

import Foundation
import NetworkExtension
import Combine

enum DashboardConnectionState: Equatable {
    case wifiDisconnected
    case joiningWifi(ssid: String)
    /// iOS accepted the hotspot configuration, but association with the network
    /// has NOT been confirmed (NEHotspotConfiguration success does not prove association).
    case wifiConfigured(ssid: String)
    case wifiAssociated(ssid: String)
    case dashboardAuthRequired(ssid: String)
    case dashboardSessionEstablished(ssid: String)
    case failed(error: String)

    var displayTitle: String {
        switch self {
        case .wifiDisconnected:
            return "Disconnected"
        case .joiningWifi(let ssid):
            return "Joining \(ssid)..."
        case .wifiConfigured(let ssid):
            return "Wi-Fi Configured (\(ssid))"
        case .wifiAssociated(let ssid):
            return "Wi-Fi Associated (\(ssid))"
        case .dashboardAuthRequired(let ssid):
            return "Auth Required (\(ssid))"
        case .dashboardSessionEstablished(let ssid):
            return "Connected (\(ssid))"
        case .failed:
            return "Connection Failed"
        }
    }

    var isAssociated: Bool {
        switch self {
        case .wifiAssociated, .dashboardAuthRequired, .dashboardSessionEstablished:
            return true
        default:
            return false
        }
    }

    var isSessionActive: Bool {
        if case .dashboardSessionEstablished = self {
            return true
        }
        return false
    }

    var ssid: String? {
        switch self {
        case .joiningWifi(let s), .wifiConfigured(let s), .wifiAssociated(let s),
             .dashboardAuthRequired(let s), .dashboardSessionEstablished(let s):
            return s
        case .wifiDisconnected, .failed:
            return nil
        }
    }
}

/// Result of probing for a Tripper Dash application protocol.
enum DashboardProtocolSupport: Equatable {
    /// No manufacturer-published or otherwise verified protocol is implemented.
    case notVerified
}

@MainActor
class DashboardConnectionManager: ObservableObject {
    static let shared = DashboardConnectionManager()

    @Published var state: DashboardConnectionState = .wifiDisconnected
    @Published var lastKnownSSID: String?
    @Published var diagnosticMessage: String?
    @Published var isVerifyingSession: Bool = false

    /// Whether ReTripper has a verified way to talk to the Tripper Dash.
    /// Royal Enfield has not published the Tripper Dash protocol, so this stays `.notVerified`.
    let protocolSupport: DashboardProtocolSupport = .notVerified

    /// True only when iOS has confirmed the phone is on the motorcycle Wi-Fi network.
    /// This is Wi-Fi association only — it does NOT mean an authenticated dashboard session.
    var isConnected: Bool { state.isAssociated }

    private let userDefaultsKey = "retripper_last_known_ssid"

    init() {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey), !saved.isEmpty {
            self.lastKnownSSID = saved
        }
    }

    // MARK: - Entry Point 1: Manual SSID Connection (P0)
    /// Connects to a motorcycle hotspot by exact SSID with optional password.
    /// Preserves exact case and underscores. Never requires camera permissions.
    func connectViaManualSSID(ssid: String, password: String?) {
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSSID.isEmpty else {
            self.state = .failed(error: "SSID cannot be empty.")
            self.diagnosticMessage = "Please enter a valid motorcycle Wi-Fi SSID."
            return
        }

        self.state = .joiningWifi(ssid: cleanSSID)
        self.diagnosticMessage = "Requesting system Wi-Fi association with \(cleanSSID)..."

        let configuration: NEHotspotConfiguration
        if let pwd = password, !pwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Password-protected network
            configuration = NEHotspotConfiguration(ssid: cleanSSID, passphrase: pwd, isWEP: false)
        } else {
            // Passwordless / Open network (Default for motorcycle hotspots)
            configuration = NEHotspotConfiguration(ssid: cleanSSID)
        }

        configuration.joinOnce = false

        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if let error = error {
                    self.handleConfigurationError(error, ssid: cleanSSID)
                } else {
                    self.handleConfigurationAccepted(ssid: cleanSSID)
                }
            }
        }
    }

    // MARK: - Entry Point 2: Scan Dashboard QR Code
    /// Parses a QR code payload from the Tripper Dash and connects to the extracted SSID.
    func connectViaQRCode(payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.state = .failed(error: "Empty QR code.")
            self.diagnosticMessage = "Scanned QR code did not contain valid motorcycle data."
            return
        }

        // Parse standard Wi-Fi QR format: WIFI:S:RE_TRIPPER_XXXX;T:WPA;P:password;; or raw SSID
        var extractedSSID: String = trimmed
        var extractedPassword: String? = nil

        if trimmed.hasPrefix("WIFI:") || trimmed.hasPrefix("wifi:") {
            let components = trimmed.components(separatedBy: ";")
            for comp in components {
                if comp.hasPrefix("S:") || comp.hasPrefix("s:") {
                    extractedSSID = String(comp.dropFirst(2))
                } else if comp.hasPrefix("P:") || comp.hasPrefix("p:") {
                    extractedPassword = String(comp.dropFirst(2))
                }
            }
        }

        connectViaManualSSID(ssid: extractedSSID, password: extractedPassword)
    }

    // MARK: - Entry Point 3: Existing Wi-Fi Connection (iOS Settings)
    /// Checks if the device is already associated with a motorcycle hotspot via iOS Settings.
    func checkExistingConnection() {
        self.diagnosticMessage = "Verifying existing Wi-Fi association..."

        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if let network = network {
                    let currentSSID = network.ssid
                    self.handleAssociationSuccess(ssid: currentSSID)
                    self.diagnosticMessage = "Detected active connection to \(currentSSID)."
                } else {
                    // Supported reporting when Access WiFi Information entitlement is restricted
                    self.diagnosticMessage = "Verification unavailable: Reading active Wi-Fi info from iOS Settings requires Apple's Access Wi-Fi Information entitlement. Please use 'Enter SSID' or 'Scan QR' to pair directly."
                    if self.state == .wifiDisconnected {
                        self.state = .failed(error: "Could not read network from iOS Settings. Use Manual SSID entry.")
                    }
                }
            }
        }
    }

    // MARK: - Session Verification
    /// Validates genuine Tripper Dash session establishment after Wi-Fi association.
    /// Attempts to establish an authenticated Tripper Dash session.
    ///
    /// ReTripper does not have a verified Tripper Dash protocol (no published endpoints,
    /// packet formats or authentication). We therefore never report a session as established;
    /// the state stays at Wi-Fi association and the diagnostics explain why.
    func verifyDashboardSession() {
        guard case .wifiAssociated(let ssid) = state else {
            if case .wifiConfigured(let ssid) = state {
                diagnosticMessage = "iOS accepted the Wi-Fi settings for \(ssid), but ReTripper has not confirmed the phone is on that network yet. Tap 'Confirm Wi-Fi' first."
            }
            return
        }

        switch protocolSupport {
        case .notVerified:
            isVerifyingSession = false
            diagnosticMessage = "Wi-Fi link to \(ssid) is confirmed, but a dashboard session cannot be established: Royal Enfield has not published the Tripper Dash communication protocol, and ReTripper will not guess endpoints or credentials. Phone-side ride features keep working without it."
        }
    }

    /// Confirms whether the phone is actually associated with the configured SSID.
    /// Requires the Access Wi-Fi Information entitlement and location permission on a real device.
    func confirmAssociation() {
        guard let expected = state.ssid else { return }
        diagnosticMessage = "Checking which Wi-Fi network the phone is using..."
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let network = network, network.ssid == expected {
                    self.handleAssociationSuccess(ssid: expected)
                } else if let network = network {
                    self.state = .wifiConfigured(ssid: expected)
                    self.diagnosticMessage = "Phone is currently on '\(network.ssid)', not '\(expected)'. Check iOS Settings ➔ Wi-Fi."
                } else {
                    self.diagnosticMessage = "iOS did not report the current Wi-Fi network. This needs the Access Wi-Fi Information entitlement (signed build) and location permission. Association for '\(expected)' is unconfirmed."
                }
            }
        }
    }

    // MARK: - Reconnection & Network Management
    /// Reconnects to the last successfully associated motorcycle SSID.
    func reconnect() {
        guard let ssid = lastKnownSSID, !ssid.isEmpty else {
            self.diagnosticMessage = "No previously paired motorcycle network saved."
            return
        }
        connectViaManualSSID(ssid: ssid, password: nil)
    }

    /// Forgets the current or last known motorcycle network and removes system configuration.
    func forgetNetwork() {
        if let ssid = lastKnownSSID {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        self.lastKnownSSID = nil
        self.state = .wifiDisconnected
        self.diagnosticMessage = "Motorcycle network forgotten."
    }

    /// Disconnects the current session.
    func disconnect() {
        self.state = .wifiDisconnected
        self.diagnosticMessage = "Disconnected from motorcycle dashboard."
    }

    // MARK: - Private Error Handling
    private func handleConfigurationAccepted(ssid: String) {
        self.lastKnownSSID = ssid
        UserDefaults.standard.set(ssid, forKey: userDefaultsKey)
        self.state = .wifiConfigured(ssid: ssid)
        self.diagnosticMessage = "iOS accepted the Wi-Fi configuration for \(ssid). Confirming association..."
        confirmAssociation()
    }

    private func handleAssociationSuccess(ssid: String) {
        self.lastKnownSSID = ssid
        UserDefaults.standard.set(ssid, forKey: userDefaultsKey)

        // Wi-Fi association succeeded. Per specifications, Wi-Fi association
        // does NOT automatically equal established application session.
        self.state = .wifiAssociated(ssid: ssid)
        self.diagnosticMessage = "Successfully associated with Wi-Fi network \(ssid). Ready for dashboard authentication."
    }

    private func handleConfigurationError(_ error: Error, ssid: String) {
        let nsError = error as NSError

        // Check for NEHotspotConfigurationError cases
        if nsError.domain == NEHotspotConfigurationErrorDomain {
            switch nsError.code {
            case 8, 13: // alreadyAssociated
                self.handleAssociationSuccess(ssid: ssid)
                self.diagnosticMessage = "Already associated with \(ssid)."
                return
            case 7: // userCanceled / userDenied
                self.state = .wifiDisconnected
                self.diagnosticMessage = "Wi-Fi association request was declined in the system dialog."
                return
            case 1, 2, 3: // invalid, invalidSSID, invalidPassphrase
                self.state = .failed(error: "Invalid network configuration or password.")
                self.diagnosticMessage = "The entered SSID or password does not match the network parameters."
                return
            case 10: // networkNotFound
                self.state = .failed(error: "Motorcycle network not found.")
                self.diagnosticMessage = "The hotspot '\(ssid)' was not detected. Ensure your motorcycle ignition and Tripper Dash Wi-Fi are turned on."
                return
            default:
                break
            }
        }

        self.state = .failed(error: error.localizedDescription)
        self.diagnosticMessage = "Connection failed: \(error.localizedDescription). You can retry without restarting."
    }
}
