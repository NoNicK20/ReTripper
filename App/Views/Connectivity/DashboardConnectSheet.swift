//
//  DashboardConnectSheet.swift
//  ReTripper
//
//  Tripper Dash Pairing & Connectivity Sheet.
//  Provides three independent entry points:
//  1. Manual SSID Entry (P0)
//  2. Scan the network name shown on the dash with the camera (text, or a Wi-Fi QR code)
//  3. Existing Wi-Fi Connection via iOS Settings
//

import SwiftUI
import NetworkExtension

struct DashboardConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connectionManager: DashboardConnectionManager

    @State private var selectedMethod: Int = 1 // 0: Enter name, 1: Scan dash, 2: iOS Settings
    @State private var manualSSID: String = ""
    @State private var manualPassword: String = ""
    @State private var requiresPassword: Bool = false
    @State private var scannedName: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header & Status Card
                        ConnectionStatusCard()

                        // Entry Point Segmented Picker
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PAIRING METHOD")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            Picker("Method", selection: $selectedMethod) {
                                Text("Enter Name").tag(0)
                                Text("Scan Dash").tag(1)
                                Text("iOS Settings").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }
                        .darkCard(padding: 14)

                        // Active Method Panel
                        if selectedMethod == 0 {
                            ManualSSIDPanel(
                                ssid: $manualSSID,
                                password: $manualPassword,
                                requiresPassword: $requiresPassword,
                                scannedName: scannedName,
                                onConnect: {
                                    connectionManager.connectViaManualSSID(
                                        ssid: manualSSID,
                                        password: requiresPassword ? manualPassword : nil
                                    )
                                }
                            )
                        } else if selectedMethod == 1 {
                            DashScanPanel { result in
                                // Never join straight from the camera: OCR can misread a letter,
                                // so the name goes into the form for the rider to check first.
                                switch result {
                                case .networkName(let name):
                                    manualSSID = name
                                    requiresPassword = false
                                    manualPassword = ""
                                    scannedName = name
                                case .wifiQR(let ssid, let password):
                                    manualSSID = ssid
                                    requiresPassword = password != nil
                                    manualPassword = password ?? ""
                                    scannedName = ssid
                                }
                                selectedMethod = 0
                            }
                        } else {
                            ExistingWiFiPanel(
                                onCheckConnection: {
                                    connectionManager.checkExistingConnection()
                                }
                            )
                        }

                        // Last Paired Network Management
                        if let lastSSID = connectionManager.lastKnownSSID {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("PAIRED MOTORCYCLE HOTSPOT")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .tracking(1.2)

                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(lastSSID)
                                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                                            .foregroundColor(Theme.textPrimary)
                                        Text("Saved local Wi-Fi profile")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textSecondary)
                                    }

                                    Spacer()

                                    Button(action: { connectionManager.reconnect() }) {
                                        Text("Reconnect")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(Theme.textPrimary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(Theme.surfaceElevated)
                                            .clipShape(Capsule())
                                    }
                                }

                                Divider()
                                    .background(Theme.borderSubtle)

                                Button(action: { connectionManager.forgetNetwork() }) {
                                    HStack {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                        Text("Forget Network Configuration")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundColor(Theme.apexRed)
                                }
                            }
                            .darkCard(padding: 16)
                        }

                        // Diagnostic Console
                        if let msg = connectionManager.diagnosticMessage {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 5) {
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textTertiary)
                                    Text("DIAGNOSTICS")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                }

                                Text(msg)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .darkCard(padding: 14)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Tripper Dash Connectivity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .onAppear {
            if let last = connectionManager.lastKnownSSID, manualSSID.isEmpty {
                manualSSID = last
            }
        }
    }
}

// MARK: - Status Card
struct ConnectionStatusCard: View {
    @EnvironmentObject private var connectionManager: DashboardConnectionManager

    private var projectionActive: Bool {
        switch connectionManager.projectionState {
        case .starting, .projecting: return true
        case .idle, .failed: return false
        }
    }

    private var projectionButtonTitle: String {
        switch connectionManager.projectionState {
        case .idle: return "Show Map on Dash"
        case .starting: return "Starting…"
        case .projecting: return "Stop Map on Dash"
        case .failed: return "Retry Map on Dash"
        }
    }

    private var projectionNote: String? {
        switch connectionManager.projectionState {
        case .projecting:
            return "Streaming the map to the dashboard screen."
        case .failed(let message):
            return message
        case .idle, .starting:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CONNECTION STATUS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .tracking(1.2)

                Spacer()

                StatusIndicator(state: connectionManager.state)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(connectionManager.state.displayTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)

                switch connectionManager.state {
                case .wifiDisconnected:
                    Text("No active Wi-Fi association with Tripper Dash. Choose a pairing method below.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)

                case .joiningWifi(let ssid):
                    Text("Attempting system association with '\(ssid)'. Please confirm the system prompt if presented.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)

                case .wifiConfigured(let ssid):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iOS accepted the Wi-Fi settings for '\(ssid)'. That alone does not prove the phone joined the network.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)

                        Button(action: { connectionManager.confirmAssociation() }) {
                            Text("Confirm Wi-Fi")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Theme.surfaceElevated)
                                .clipShape(Capsule())
                        }
                    }

                case .wifiAssociated(let ssid):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Phone is on Wi-Fi network '\(ssid)'. Pair with the dashboard to show navigation on the Tripper Dash.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)

                        Button(action: { connectionManager.verifyDashboardSession() }) {
                            HStack(spacing: 6) {
                                if connectionManager.isVerifyingSession {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text("Check Dashboard Session")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.apexRed)
                            .clipShape(Capsule())
                        }
                        .disabled(connectionManager.isVerifyingSession)
                    }

                case .dashboardAuthRequired:
                    Text(connectionManager.diagnosticMessage ?? "Pairing with the Tripper Dash…")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)

                case .dashboardSessionEstablished:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dashboard connected. Show the ReTripper map on the Tripper Dash screen.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)

                        Button(action: { connectionManager.toggleProjection() }) {
                            HStack(spacing: 6) {
                                Image(systemName: projectionActive ? "stop.fill" : "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text(projectionButtonTitle)
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(projectionActive ? Theme.surfaceElevated : Theme.apexRed)
                            .clipShape(Capsule())
                        }

                        if let note = projectionNote {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }

                case .failed(let err):
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.apexRed)
                }
            }

            if connectionManager.state.isAssociated || connectionManager.state.ssid != nil {
                Button(action: { connectionManager.disconnect() }) {
                    Text("Disconnect Session")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .darkCard(padding: 16)
    }
}

struct StatusIndicator: View {
    let state: DashboardConnectionState

    private var color: Color {
        switch state {
        case .wifiDisconnected: return Theme.textTertiary
        case .joiningWifi, .wifiConfigured, .dashboardAuthRequired: return Theme.textSecondary
        case .wifiAssociated: return Theme.textPrimary
        case .dashboardSessionEstablished: return Theme.apexRed
        case .failed: return Theme.apexRedDark
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.isSessionActive ? "AUTHENTICATED" : (state.isAssociated ? "WI-FI LINKED" : "OFFLINE"))
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceSecondary)
        .clipShape(Capsule())
    }
}

// MARK: - Method 1: Manual SSID Panel (P0)
struct ManualSSIDPanel: View {
    @Binding var ssid: String
    @Binding var password: String
    @Binding var requiresPassword: Bool
    var scannedName: String? = nil
    let onConnect: () -> Void

    private var isConnectDisabled: Bool {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MOTORCYCLE NETWORK NAME")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .tracking(1.2)

            Text("On the bike, hold the joystick for 3 seconds until the dash shows its network name (for example RE_MVWW_260317). Type it exactly as shown, or use Scan Dash.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            if let scanned = scannedName, scanned == ssid {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.viewfinder")
                        .foregroundColor(Theme.apexRed)
                    Text("Read from the camera. Check every letter and number against the dash before connecting.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(spacing: 12) {
                // Exact SSID Text Field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Network name (exact capitals and underscores)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)

                    TextField("e.g. RE_MVWW_260317", text: $ssid)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .foregroundColor(Theme.textPrimary)
                        .padding(12)
                        .background(Theme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.borderSubtle, lineWidth: 1)
                        )
                }

                // Password toggle (Default: OFF / passwordless)
                Toggle(isOn: $requiresPassword) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use a different Wi-Fi password")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text("ReTripper uses the standard Tripper Dash password automatically. Turn this on only if your dash was set to a custom one.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .tint(Theme.apexRed)
                .padding(.vertical, 4)

                // Optional Password Field
                if requiresPassword {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WPA2 Passphrase")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textSecondary)

                        SecureField("Enter Wi-Fi password", text: $password)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .foregroundColor(Theme.textPrimary)
                            .padding(12)
                            .background(Theme.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Theme.borderSubtle, lineWidth: 1)
                            )
                    }
                }

                // Connect Button
                Button(action: onConnect) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi")
                            .font(.system(size: 14, weight: .bold))
                        Text("Connect to Motorcycle Wi-Fi")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.apexRed)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                }
                .disabled(isConnectDisabled)
                .opacity(isConnectDisabled ? 0.45 : 1.0)
                .padding(.top, 6)
            }
        }
        .darkCard(padding: 16)
    }
}

// MARK: - Method 2: Scan the dash with the camera
struct DashScanPanel: View {
    let onFound: (DashScanResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SCAN THE DASH")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Turn the ignition on.")
                Text("2. Hold the joystick on the right switch for 3 seconds. The dash shows a name like RE_MVWW_260317.")
                Text("3. Point the camera at the name. You'll check it before connecting.")
            }
            .font(.system(size: 12))
            .foregroundColor(Theme.textSecondary)

            DashTextScannerView(onFound: onFound)
                .frame(height: 260)
                .background(Theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.borderSubtle, lineWidth: 1)
                )
        }
        .darkCard(padding: 16)
    }
}

// MARK: - Method 3: Existing Wi-Fi Panel
struct ExistingWiFiPanel: View {
    let onCheckConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EXISTING WI-FI (IOS SETTINGS)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .tracking(1.2)

            Text("If you already connected your iPhone to the motorcycle's Wi-Fi network in iOS Settings ➔ Wi-Fi, verify the link here.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "1.circle.fill")
                        .foregroundColor(Theme.apexRed)
                    Text("Open iPhone Settings ➔ Wi-Fi")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "2.circle.fill")
                        .foregroundColor(Theme.apexRed)
                    Text("Select your motorcycle hotspot (RE_...)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "3.circle.fill")
                        .foregroundColor(Theme.apexRed)
                    Text("Return to ReTripper and tap Check Connection")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            .padding(.vertical, 4)

            Button(action: onCheckConnection) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                    Text("Verify Existing Connection")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .stroke(Theme.borderSubtle, lineWidth: 1)
                )
            }
        }
        .darkCard(padding: 16)
    }
}

#Preview {
    DashboardConnectSheet()
        .environmentObject(DashboardConnectionManager.shared)
}
