//
//  RideModeView.swift
//  ReTripper
//
//  Dedicated riding interface: full map / turn-by-turn / trip / compass panels,
//  compact music controls, call and contextual alert overlay, audio controls,
//  dashboard status and ride lifecycle controls.
//

import SwiftUI

enum RidePanel: String, CaseIterable, Identifiable {
    case map = "Map"
    case turnByTurn = "Turns"
    case trip = "Trip"
    case compass = "Compass"
    var id: String { rawValue }
}

struct RideModeView: View {
    @EnvironmentObject private var session: RideSessionManager
    @EnvironmentObject private var dataManager: DataManager

    @State private var panel: RidePanel = .map
    @State private var showingSearch = false
    @State private var showingAudio = false
    @State private var showingDashboard = false
    @State private var confirmEnd = false

    var body: some View {
        RideModeContent(session: session,
                        navigation: session.navigation,
                        tripMeter: session.tripMeter,
                        location: session.location,
                        google: session.google,
                        dashboard: session.dashboard,
                        audio: session.audio,
                        panel: $panel,
                        showingSearch: $showingSearch,
                        showingAudio: $showingAudio,
                        showingDashboard: $showingDashboard,
                        confirmEnd: $confirmEnd,
                        unit: dataManager.distanceUnit,
                        onEnd: { _ = session.endRide(dataManager: dataManager) })
            .onAppear { session.rideScreenAppeared() }
            .onDisappear { session.rideScreenDisappeared() }
    }
}

/// Split out so each subsystem is observed explicitly.
private struct RideModeContent: View {
    @ObservedObject var session: RideSessionManager
    @ObservedObject var navigation: NavigationManager
    @ObservedObject var tripMeter: TripMeterManager
    @ObservedObject var location: LocationService
    @ObservedObject var google: GoogleNavigationController
    @ObservedObject var dashboard: DashboardConnectionManager
    @ObservedObject var audio: NavigationAudioManager
    @Binding var panel: RidePanel
    @Binding var showingSearch: Bool
    @Binding var showingAudio: Bool
    @Binding var showingDashboard: Bool
    @Binding var confirmEnd: Bool
    let unit: DistanceUnit
    let onEnd: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                Picker("Panel", selection: $panel) {
                    ForEach(RidePanel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)

                mainPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .padding(.horizontal, 12)

                if panel == .map, let p = navigation.progress, navigation.status.isActive {
                    compactManeuver(p)
                }

                NowPlayingCard(music: session.music)
                    .padding(.horizontal, 12)

                controls
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            RideAlertOverlay(alerts: session.alerts)
                .padding(.top, 56)
        }
        .sheet(isPresented: $showingSearch) {
            DestinationSearchSheet(navigation: navigation,
                                   store: DestinationStore.shared,
                                   origin: location.latestLocation?.coordinate,
                                   googleStatus: google.status,
                                   onStart: { session.startNavigation(); panel = .turnByTurn },
                                   onRequestGoogleTerms: { google.requestTermsAcceptance { _ in } })
        }
        .sheet(isPresented: $showingAudio) {
            AudioGuidanceSheet(audio: session.audio, music: session.music)
        }
        .sheet(isPresented: $showingDashboard) {
            DashboardRideSheet(connection: session.dashboard, navigation: navigation)
        }
        .confirmationDialog("End ride?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End and save ride", role: .destructive, action: onEnd)
            if session.recoveredFromInterruption {
                Button("Discard recovered ride", role: .destructive) { session.discardRecoveredRide() }
            }
        } message: {
            Text("Trip A will be saved to ride history and added to the odometer.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showingDashboard = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: dashboard.state.isAssociated ? "wifi" : "wifi.slash")
                    Text(dashboard.state.isAssociated ? "TRIPPER WI-FI" : "NO DASH")
                }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundColor(dashboard.state.isAssociated ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 10).frame(minHeight: 36)
                .background(Theme.surfaceSecondary).clipShape(Capsule())
            }
            .buttonStyle(.plain)

            gpsBadge

            Spacer()

            Text(RideFormat.speedKmh(tripMeter.currentSpeedMps))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
            Text("km/h").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.textSecondary)

            Button { showingAudio = true } label: {
                Image(systemName: audio.mode == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceSecondary).clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio guidance settings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var gpsBadge: some View {
        let accuracy = location.latestLocation?.horizontalAccuracy ?? -1
        let good = accuracy >= 0 && accuracy <= 20
        let text: String
        if !location.isAuthorized && location.authorization != .notDetermined {
            text = "GPS OFF"
        } else if accuracy < 0 {
            text = "GPS …"
        } else {
            text = good ? "GPS" : "GPS WEAK"
        }
        return Text(text)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundColor(good ? Theme.textPrimary : Theme.apexRed)
            .padding(.horizontal, 10).frame(minHeight: 36)
            .background(Theme.surfaceSecondary).clipShape(Capsule())
    }

    // MARK: Panels

    @ViewBuilder
    private var mainPanel: some View {
        if !location.isAuthorized && location.authorization != .notDetermined {
            VStack(spacing: 12) {
                Image(systemName: "location.slash").font(.system(size: 44)).foregroundColor(Theme.textTertiary)
                Text("Location access is off").font(.system(size: 18, weight: .bold)).foregroundColor(Theme.textPrimary)
                Text("ReTripper needs location access to record rides, navigate and show the compass course.")
                    .font(.system(size: 13)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 15, weight: .bold)).foregroundColor(Theme.apexRed)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        } else {
            switch panel {
            case .map:
                RideMapView(navigation: navigation, tripMeter: tripMeter,
                            useGoogle: session.usesGoogleNavigation,
                            voiceEnabled: audio.mode != .muted)
            case .turnByTurn:
                TurnByTurnView(navigation: navigation, onSearch: { showingSearch = true })
            case .trip:
                ScrollView { TripMeterPanel(tripMeter: tripMeter, unit: unit) }
            case .compass:
                ScrollView {
                    DigitalCompassView(compass: session.compass)
                }
            }
        }
    }

    private func compactManeuver(_ p: RouteProgress) -> some View {
        Button { panel = .turnByTurn } label: {
            HStack(spacing: 12) {
                Image(systemName: p.nextManeuver.symbolName)
                    .font(.system(size: 30, weight: .heavy)).foregroundColor(Theme.textPrimary)
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text(RideFormat.distance(p.distanceToNextManeuverMeters))
                        .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundColor(Theme.apexRed)
                    Text(p.nextInstruction).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(RideFormat.distance(p.remainingDistanceMeters))
                        .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textPrimary)
                    if p.remainingSeconds > 0 {
                        Text("ETA \(RideFormat.clock(p.eta))").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .darkCard(padding: 10)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            switch session.rideState {
            case .idle:
                BigRideButton(title: "Start ride", symbol: "record.circle", filled: true) { session.startRide() }
            case .recording:
                BigRideButton(title: "Pause", symbol: "pause.fill") { session.pauseRide() }
                BigRideButton(title: "End", symbol: "stop.fill", filled: true) { confirmEnd = true }
            case .paused:
                BigRideButton(title: "Resume", symbol: "play.fill", filled: true) { session.resumeRide() }
                BigRideButton(title: "End", symbol: "stop.fill") { confirmEnd = true }
            }

            if navigation.status.isActive || navigation.status == .arrived {
                BigRideButton(title: "Stop nav", symbol: "xmark") { session.stopNavigation() }
            } else {
                BigRideButton(title: "Navigate", symbol: "magnifyingglass") { showingSearch = true }
            }
        }
    }
}

// MARK: - Dashboard status and preview

struct DashboardRideSheet: View {
    @ObservedObject var connection: DashboardConnectionManager
    @ObservedObject var navigation: NavigationManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingPairing = false

    private var registry: DashboardCapabilityRegistry {
        DashboardCapabilityRegistry(protocolSupport: connection.protocolSupport,
                                    sessionEstablished: connection.state.isSessionActive)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            RideLabel(text: "LINK STATUS")
                            row("Wi-Fi", connection.state.displayTitle)
                            row("Dashboard session", connection.state.isSessionActive ? "Established" : "Not established")
                            Text("Wi-Fi association and a dashboard session are separate. A session needs a verified Tripper Dash protocol, which is not available.")
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                            BigRideButton(title: "Pair / manage Tripper Wi-Fi", symbol: "wifi") { showingPairing = true }
                        }
                        .darkCard(padding: 14)

                        VStack(alignment: .leading, spacing: 10) {
                            RideLabel(text: "DASHBOARD CAPABILITIES")
                            ForEach(DashboardCapability.allCases) { cap in
                                let availability = registry.availability(of: cap)
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: availability.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                        .foregroundColor(availability.isAvailable ? Theme.apexRed : Theme.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cap.rawValue).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.textPrimary)
                                        if case .unavailable(let reason) = availability {
                                            Text(reason).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                                        }
                                    }
                                }
                            }
                        }
                        .darkCard(padding: 14)

                        VStack(spacing: 10) {
                            Text("PREVIEW — NOT SENT TO THE MOTORCYCLE")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .foregroundColor(Theme.apexRed)
                            ZStack {
                                Circle().fill(Color.black)
                                Circle().stroke(Theme.border, lineWidth: 6)
                                VStack(spacing: 6) {
                                    Image(systemName: navigation.progress?.nextManeuver.symbolName ?? "location.north.fill")
                                        .font(.system(size: 54, weight: .heavy)).foregroundColor(.white)
                                    Text(navigation.progress.map { RideFormat.distance($0.distanceToNextManeuverMeters) } ?? "--")
                                        .font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundColor(Theme.apexRed)
                                    Text(navigation.progress?.nextRoadName ?? "No active route")
                                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSecondary)
                                        .lineLimit(1).frame(maxWidth: 150)
                                }
                            }
                            .frame(width: 220, height: 220)
                            Text("Illustration of the data a round dashboard could show. ReTripper cannot display anything on the real Tripper Dash.")
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .darkCard(padding: 14)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Tripper Dash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingPairing) {
                DashboardConnectSheet().environmentObject(connection)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textPrimary)
        }
    }
}
