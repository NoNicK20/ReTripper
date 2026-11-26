//
//  RideModeView.swift
//  ReTripper
//
//  Dedicated riding interface. In Map mode the real Google Maps view fills the
//  whole display (edge to edge) and ReTripper's overlays sit inside the safe
//  area, clear of the Dynamic Island, status bar and home indicator. The map's
//  padding is measured from those overlays so Google's logo, compass and
//  re-centre controls always stay visible.
//

import SwiftUI

enum RidePanel: String, CaseIterable, Identifiable {
    case map = "Map"
    case turnByTurn = "Turns"
    case trip = "Trip"
    case compass = "Compass"
    var id: String { rawValue }
}

private struct TopOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BottomOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct RideModeView: View {
    @EnvironmentObject private var session: RideSessionManager
    @EnvironmentObject private var dataManager: DataManager

    var body: some View {
        RideModeContent(session: session,
                        navigation: session.navigation,
                        tripMeter: session.tripMeter,
                        location: session.location,
                        google: session.google,
                        dashboard: session.dashboard,
                        audio: session.audio,
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
    let unit: DistanceUnit
    let onEnd: () -> Void

    @State private var panel: RidePanel = .map
    @State private var showingSearch = false
    @State private var showingAudio = false
    @State private var showingDashboard = false
    @State private var confirmEnd = false
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Layer 1: full-bleed map or black background.
                if panel == .map {
                    GoogleMapSurface(google: google, padding: mapPadding(safe: geo.safeAreaInsets))
                        .ignoresSafeArea()
                } else {
                    Theme.background.ignoresSafeArea()
                }

                // Layer 2: overlays inside the safe area.
                VStack(spacing: 6) {
                    VStack(spacing: 6) {
                        topBar
                        Picker("Panel", selection: $panel) {
                            ForEach(RidePanel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .background(Color.black.opacity(0.85).clipShape(RoundedRectangle(cornerRadius: 8)))
                        if panel == .map {
                            DirectionCard(navigation: navigation)
                            RideAlertOverlay(alerts: session.alerts)
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TopOverlayHeightKey.self, value: g.size.height)
                    })

                    if panel == .map {
                        Spacer(minLength: 0)
                    } else {
                        RideAlertOverlay(alerts: session.alerts)
                        panelContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    VStack(spacing: 6) {
                        if panel == .map {
                            if let diag = google.lastRouteDiagnostic {
                                Text(diag)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.black.opacity(0.85))
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                            }
                            HStack(alignment: .bottom) {
                                RouteSummaryStrip(navigation: navigation, tripMeter: tripMeter, unit: unit)
                                mapButtons
                            }
                        }
                        NowPlayingCard(music: session.music)
                        controls
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: BottomOverlayHeightKey.self, value: g.size.height)
                    })
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .onPreferenceChange(TopOverlayHeightKey.self) { topHeight = $0 }
            .onPreferenceChange(BottomOverlayHeightKey.self) { bottomHeight = $0 }
        }
        .sheet(isPresented: $showingSearch) {
            DestinationSearchSheet(navigation: navigation,
                                   store: DestinationStore.shared,
                                   google: google,
                                   origin: location.latestLocation?.coordinate,
                                   onPreview: { session.previewRoute(); panel = .map },
                                   onStart: { session.startNavigation(); panel = .map })
        }
        .sheet(isPresented: $showingAudio) {
            AudioGuidanceSheet(audio: audio, music: session.music, google: google,
                               onRepeat: { session.repeatInstruction() })
        }
        .sheet(isPresented: $showingDashboard) {
            DashboardRideSheet(connection: dashboard, navigation: navigation)
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

    /// Map padding = safe area + overlay heights, so Google's attribution and controls stay visible.
    private func mapPadding(safe: EdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: safe.top + topHeight + 8, left: safe.leading + 4,
                     bottom: safe.bottom + bottomHeight + 8, right: safe.trailing + 4)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showingDashboard = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: dashboard.state.isAssociated ? "wifi" : "wifi.slash")
                    Text(dashboard.state.isAssociated ? "TRIPPER WI-FI" : "NO DASH")
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundColor(dashboard.state.isAssociated ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 10).frame(minHeight: 40)
                .background(Color.black.opacity(0.85)).clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tripper Dash status")

            gpsBadge

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(RideFormat.speedKmh(tripMeter.currentSpeedMps))
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()
                Text("km/h").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 10).frame(minHeight: 36)
            .background(Color.black.opacity(0.85)).clipShape(Capsule())

            Button { showingAudio = true } label: {
                Image(systemName: audio.mode == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.85)).clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio guidance settings")
        }
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
            .lineLimit(1)
            .padding(.horizontal, 10).frame(minHeight: 40)
            .background(Color.black.opacity(0.85)).clipShape(Capsule())
    }

    private var lightingSymbol: String {
        switch google.lighting {
        case .auto: return "circle.lefthalf.filled"
        case .day: return "sun.max.fill"
        case .night: return "moon.fill"
        }
    }

    private var mapButtons: some View {
        VStack(spacing: 8) {
            roundButton(lightingSymbol, label: "Map lighting: \(google.lighting.rawValue)") {
                let all = MapLighting.allCases
                let index = all.firstIndex(of: google.lighting) ?? 0
                google.lighting = all[(index + 1) % all.count]
            }
            roundButton(google.showsTraffic ? "car.fill" : "car", label: "Traffic") { google.showsTraffic.toggle() }
        }
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.85))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Panels

    @ViewBuilder
    private var panelContent: some View {
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
        } else {
            switch panel {
            case .map:
                EmptyView()
            case .turnByTurn:
                TurnByTurnView(navigation: navigation, onSearch: { showingSearch = true })
            case .trip:
                ScrollView { TripMeterPanel(tripMeter: tripMeter, unit: unit) }
            case .compass:
                ScrollView { DigitalCompassView(compass: session.compass) }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            switch session.rideState {
            case .idle:
                BigRideButton(title: "Start ride", symbol: "record.circle", filled: !navigation.status.isActive) { session.startRide() }
            case .recording:
                BigRideButton(title: "Pause", symbol: "pause.fill") { session.pauseRide() }
                BigRideButton(title: "End ride", symbol: "stop.fill") { confirmEnd = true }
            case .paused:
                BigRideButton(title: "Resume", symbol: "play.fill", filled: true) { session.resumeRide() }
                BigRideButton(title: "End ride", symbol: "stop.fill") { confirmEnd = true }
            }

            if navigation.status.isActive || navigation.status == .arrived {
                BigRideButton(title: "End nav", symbol: "xmark", filled: true) { session.stopNavigation() }
            } else if navigation.status == .preview {
                BigRideButton(title: "Start nav", symbol: "location.north.fill", filled: true) { session.startNavigation() }
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
                            Text("Google Maps is not projected to the Tripper Dash. That needs a verified dashboard interface and a Google Maps Platform licensing review.")
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
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
                            Text("Illustration of turn data a round dashboard could show. ReTripper cannot display anything on the real Tripper Dash.")
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
