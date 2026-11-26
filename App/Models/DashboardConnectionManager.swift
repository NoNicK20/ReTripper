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

    /// The real control-plane link to the dash (community K1G protocol).
    let dashLink = DashLink()
    /// Streams the ReTripper map to the dash screen once a session is up.
    private var projection: DashProjection?
    @Published private(set) var projectionState: DashProjection.State = .idle
    private var cancellables = Set<AnyCancellable>()
    /// SSID captured when a dash session attempt starts, so link-state
    /// changes can be reflected back onto the manager's own state.
    private var sessionSSID: String?

    /// True only when iOS has confirmed the phone is on the motorcycle Wi-Fi network.
    /// This is Wi-Fi association only — it does NOT mean an authenticated dashboard session.
    var isConnected: Bool { state.isAssociated }

    /// Control-stick / dash-button presses from the bike (right/left/down/click).
    var buttonEvents: AnyPublisher<DashButton, Never> { dashLink.buttonEvents.eraseToAnyPublisher() }

    private let userDefaultsKey = "retripper_last_known_ssid"

    init() {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey), !saved.isEmpty {
            self.lastKnownSSID = saved
        }
        dashLink.$state
            .sink { [weak self] linkState in self?.applyDashLinkState(linkState) }
            .store(in: &cancellables)

        let projection = DashProjection(link: dashLink)
        self.projection = projection
        projection.$state
            .sink { [weak self] s in self?.projectionState = s }
            .store(in: &cancellables)

        // The dash's own Navigation page waits for the phone to project; if
        // the rider activates it with the stick before (or after) projection
        // is up, start it so the page shows the map instead of timing out.
        dashLink.buttonEvents
            .sink { [weak self] _ in self?.startProjectionIfNeeded() }
            .store(in: &cancellables)
    }

    /// Start the map projection if the dash is connected and nothing is
    /// streaming yet (idle or previously failed). A no-op while projecting.
    private func startProjectionIfNeeded() {
        guard dashLink.state.isConnected, let projection else { return }
        switch projection.state {
        case .idle, .failed: projection.start()
        case .starting, .projecting: break
        }
    }

    /// Start or stop streaming the ReTripper map to the dash screen.
    func toggleProjection() {
        guard let projection else { return }
        switch projection.state {
        case .idle, .failed: projection.start()
        case .starting, .projecting: projection.stop()
        }
    }

    /// Mirror the dash link's state onto the manager's own connection state,
    /// which the UI binds to.
    private func applyDashLinkState(_ linkState: DashLink.State) {
        guard let ssid = sessionSSID ?? state.ssid ?? lastKnownSSID else { return }
        switch linkState {
        case .idle:
            break
        case .connecting, .handshaking:
            isVerifyingSession = true
            state = .dashboardAuthRequired(ssid: ssid)
            diagnosticMessage = dashLink.lastMessage ?? "Pairing with the dashboard…"
        case .connected:
            isVerifyingSession = false
            state = .dashboardSessionEstablished(ssid: ssid)
            diagnosticMessage = dashLink.lastMessage ?? "Connected to the dashboard."
            // Put the map on the dash as soon as it's connected — no need to
            // press Start map. The rider can still stop/restart it manually.
            startProjectionIfNeeded()
        case .failed(let message):
            isVerifyingSession = false
            // A dash-session failure doesn't drop the Wi-Fi association.
            state = .wifiAssociated(ssid: ssid)
            diagnosticMessage = message
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

        // Tripper Dash access points all use one fixed WPA2 password. Unless the
        // rider typed a custom one, use that standard password for RE_ networks.
        let customPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let passphrase: String?
        if let custom = customPassword, !custom.isEmpty {
            passphrase = custom
        } else if DashboardWiFi.looksLikeTripperSSID(cleanSSID) {
            passphrase = DashboardWiFi.tripperPassphrase
        } else {
            passphrase = nil
        }

        self.diagnosticMessage = passphrase == nil
            ? "Joining open network \(cleanSSID)..."
            : "Joining \(cleanSSID) with the standard Tripper Wi-Fi password..."

        let configuration: NEHotspotConfiguration
        if let passphrase {
            configuration = NEHotspotConfiguration(ssid: cleanSSID, passphrase: passphrase, isWEP: false)
        } else {
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

        if let wifi = DashboardPairingText.parseWiFiPayload(trimmed) {
            connectViaManualSSID(ssid: wifi.ssid, password: wifi.password)
        } else {
            connectViaManualSSID(ssid: DashboardPairingText.extractSSID(from: trimmed) ?? trimmed, password: nil)
        }
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
        // Establish the real control-plane session (community K1G protocol).
        // DashLink runs the initial burst, RSA handshake and 1 Hz heartbeat;
        // applyDashLinkState() reflects its progress onto `state`.
        sessionSSID = ssid
        isVerifyingSession = true
        diagnosticMessage = "Pairing with the dashboard…"
        dashLink.connect(ssid: ssid)
    }

    /// End the dash session (if any) without forgetting the Wi-Fi.
    func endDashboardSession() {
        dashLink.disconnect()
        if let ssid = sessionSSID ?? state.ssid {
            state = .wifiAssociated(ssid: ssid)
        }
    }

    /// Confirms whether the phone is actually associated with the configured SSID.
    /// Requires the Access Wi-Fi Information entitlement and location permission on a real device.
    func confirmAssociation(attempt: Int = 1) {
        guard let expected = state.ssid else { return }
        let maxAttempts = 4
        diagnosticMessage = "Checking which Wi-Fi network the phone is using (try \(attempt) of \(maxAttempts))..."
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor [weak self] in
                guard let self = self, self.state.ssid == expected else { return }
                if let network = network, network.ssid == expected {
                    self.handleAssociationSuccess(ssid: expected)
                    return
                }
                // Joining a network takes a few seconds after iOS accepts the settings.
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.confirmAssociation(attempt: attempt + 1)
                    return
                }
                self.state = .wifiConfigured(ssid: expected)
                if let network = network {
                    self.diagnosticMessage = "The phone is on '\(network.ssid)', not '\(expected)'. iOS did not switch to the motorcycle network. Check that the name matches the dash exactly (letters, numbers, underscores) and that the dash is showing its network name."
                } else {
                    self.diagnosticMessage = "ReTripper can't read which Wi-Fi the phone is on (iOS only allows this for builds signed with the Access Wi-Fi Information capability, with location allowed). Open iPhone Settings ➔ Wi-Fi: if '\(expected)' has a tick, the phone joined. If iOS said 'Unable to join', the dash probably needs a password that ReTripper does not have."
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
        projection?.stop()
        dashLink.disconnect()
        sessionSSID = nil
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

        if nsError.domain == NEHotspotConfigurationErrorDomain {
            switch HotspotApplyOutcome.classify(code: nsError.code) {
            case .alreadyConnected:
                self.handleAssociationSuccess(ssid: ssid)
                self.diagnosticMessage = "Already connected to \(ssid)."
                return
            case .userDeclined:
                self.state = .wifiDisconnected
                self.diagnosticMessage = "You tapped Cancel on iPhone's 'join Wi-Fi network' question."
                return
            case .badNameOrPassword:
                self.state = .failed(error: "iOS rejected the network name or password.")
                self.diagnosticMessage = "iOS rejected the network name or password for '\(ssid)'. A Wi-Fi password must be 8 to 63 characters."
                return
            case .notAllowedForThisBuild:
                self.state = .failed(error: "iOS refused the Wi-Fi request.")
                self.diagnosticMessage = "iOS refused to let ReTripper set up Wi-Fi (error \(nsError.code)). This usually means the installed app was not signed with Apple's Hotspot Configuration capability."
                return
            case .appNotInForeground:
                self.state = .failed(error: "ReTripper must be open on screen.")
                self.diagnosticMessage = "Keep ReTripper open on screen while it joins the motorcycle Wi-Fi, then try again."
                return
            case .otherFailure:
                break
            }
        }

        self.state = .failed(error: error.localizedDescription)
        self.diagnosticMessage = "Connection failed (\(nsError.domain) \(nsError.code)): \(error.localizedDescription). If this keeps happening, check that the installed app was signed with the Hotspot Configuration capability."
    }
}
