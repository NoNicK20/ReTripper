//
//  RideNavigationViews.swift
//  ReTripper
//
//  Full-map view (Apple MapKit, or Google's embedded navigation map when the
//  SDK and key are configured), distraction-minimising turn-by-turn view and
//  destination search with saved places, recents, waypoints and alternatives.
//

import SwiftUI
import MapKit

// MARK: - Full map

struct RideMapView: View {
    @ObservedObject var navigation: NavigationManager
    @ObservedObject var tripMeter: TripMeterManager
    let useGoogle: Bool
    let voiceEnabled: Bool

    @AppStorage("retripper_map_traffic") private var showsTraffic = true
    @AppStorage("retripper_map_night") private var nightMode = true
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            mapContent
            HStack(spacing: 8) {
                Text(engineLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.7)).clipShape(Capsule())
                if !isGoogleActive {
                    mapToggle(showsTraffic ? "car.fill" : "car", label: "Traffic") { showsTraffic.toggle() }
                    mapToggle(nightMode ? "moon.fill" : "sun.max.fill", label: "Day/Night") { nightMode.toggle() }
                    mapToggle("location.north.line.fill", label: "Follow") {
                        position = .userLocation(followsHeading: true, fallback: .automatic)
                    }
                }
            }
            .padding(10)
        }
    }

    private var isGoogleActive: Bool {
        useGoogle && navigation.engine == .googleNavigationSDK && navigation.status != .idle
    }

    private var engineLabel: String {
        isGoogleActive ? "GOOGLE MAPS NAVIGATION SDK" : "APPLE MAPS (MAPKIT)"
    }

    @ViewBuilder
    private var mapContent: some View {
        #if canImport(GoogleNavigation)
        if isGoogleActive {
            GoogleNavigationMapView(stops: navigation.stops, voiceEnabled: voiceEnabled) { update in
                navigation.applyGoogleUpdate(update)
            }
        } else {
            appleMap
        }
        #else
        appleMap
        #endif
    }

    private var appleMap: some View {
        Map(position: $position) {
            UserAnnotation()
            if tripMeter.route.count > 1 {
                MapPolyline(coordinates: tripMeter.route.map { $0.coordinate })
                    .stroke(Color.white.opacity(0.55), lineWidth: 4)
            }
            if let route = navigation.activeRoute {
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Theme.apexRed, lineWidth: 7)
            } else {
                ForEach(Array(navigation.candidateRoutes.enumerated()), id: \.element.id) { index, route in
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(index == navigation.selectedRouteIndex ? Theme.apexRed : Color.gray.opacity(0.7),
                                lineWidth: index == navigation.selectedRouteIndex ? 7 : 5)
                }
            }
            ForEach(navigation.stops) { stop in
                Marker(stop.name, systemImage: stop == navigation.stops.last ? "flag.checkered" : "mappin",
                       coordinate: stop.coordinate)
                    .tint(Theme.apexRed)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .all, showsTraffic: showsTraffic))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapUserLocationButton()
        }
        .environment(\.colorScheme, nightMode ? .dark : .light)
    }

    private func mapToggle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.75))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Turn-by-turn

struct TurnByTurnView: View {
    @ObservedObject var navigation: NavigationManager
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch navigation.status {
            case .navigating, .rerouting:
                if let p = navigation.progress {
                    activeGuidance(p)
                } else {
                    waiting("Waiting for GPS position on the route…")
                }
            case .arrived:
                waiting("Arrived at \(navigation.stops.last?.name ?? "destination")", symbol: "flag.checkered")
            case .calculating:
                waiting("Calculating route…", symbol: "hourglass")
            case .preview:
                waiting("Route ready. Start navigation to see live directions.", symbol: "arrow.triangle.turn.up.right.diamond")
            case .failed(let message):
                waiting(message, symbol: "exclamationmark.triangle")
            case .idle:
                VStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .font(.system(size: 54)).foregroundColor(Theme.textTertiary)
                    Text("No active route").font(.system(size: 18, weight: .bold)).foregroundColor(Theme.textPrimary)
                    BigRideButton(title: "Choose destination", symbol: "magnifyingglass", filled: true, action: onSearch)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func activeGuidance(_ p: RouteProgress) -> some View {
        VStack(spacing: 18) {
            if navigation.status == .rerouting {
                Text("REROUTING…")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.apexRed).clipShape(Capsule())
            }

            Image(systemName: p.nextManeuver.symbolName)
                .font(.system(size: 120, weight: .heavy))
                .foregroundColor(Theme.textPrimary)
                .frame(height: 150)
                .accessibilityLabel(p.nextInstruction)

            Text(RideFormat.distance(p.distanceToNextManeuverMeters))
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.apexRed)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text(p.nextInstruction)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if let road = p.nextRoadName {
                Text(road.uppercased())
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if navigation.engine == .appleMapKit {
                ProgressView(value: p.fractionComplete)
                    .tint(Theme.apexRed)
            }
            HStack(spacing: 12) {
                RideMetric(label: "REMAINING", value: RideFormat.distance(p.remainingDistanceMeters))
                RideMetric(label: "ETA", value: p.remainingSeconds > 0 ? RideFormat.clock(p.eta) : "—")
            }
            Text("Live guidance · \(navigation.engine.rawValue)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
    }

    private func waiting(_ text: String, symbol: String = "location.circle") -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 54)).foregroundColor(Theme.textTertiary)
            Text(text).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Destination search

struct DestinationSearchSheet: View {
    @ObservedObject var navigation: NavigationManager
    @ObservedObject var store: DestinationStore
    let origin: CLLocationCoordinate2D?
    let googleStatus: GoogleMapsStatus
    let onStart: () -> Void
    let onRequestGoogleTerms: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Destination] = []
    @State private var isSearching = false
    @State private var addingWaypoint = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    providerSection

                    if !navigation.stops.isEmpty { stopsSection }

                    if !navigation.candidateRoutes.isEmpty && googleStatus != .ready { routesSection }

                    if !results.isEmpty {
                        Section("Results") { ForEach(results) { row($0) } }
                    }
                    if query.isEmpty {
                        if !store.saved.isEmpty {
                            Section("Saved") { ForEach(store.saved) { row($0) } }
                        }
                        if !store.recent.isEmpty {
                            Section {
                                ForEach(store.recent) { row($0) }
                            } header: {
                                HStack {
                                    Text("Recent")
                                    Spacer()
                                    Button("Clear") { store.clearRecent() }.font(.system(size: 12))
                                }
                            }
                        }
                        Section {
                            Button {
                                if let text = UIPasteboard.general.string, let d = DestinationLinkParser.parse(text) {
                                    choose(d)
                                }
                            } label: {
                                Label("Paste shared map link", systemImage: "doc.on.clipboard")
                            }
                        } footer: {
                            Text("Supports Google Maps and Apple Maps links with coordinates, geo: links, and retripper:// links.")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: addingWaypoint ? "Add a stop" : "Search destination")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .navigationTitle(addingWaypoint ? "Add Stop" : "Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var providerSection: some View {
        Section {
            Text(googleStatus.summary).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            if googleStatus == .termsNotAccepted {
                Button("Review Google navigation terms", action: onRequestGoogleTerms)
            }
            Text("Place search uses Apple Maps. MapKit has no motorcycle mode, so car routing is used\(googleStatus == .ready ? " for previews; Google navigation uses its two-wheeler mode where available" : "").")
                .font(.system(size: 11)).foregroundColor(Theme.textTertiary)
        }
    }

    private var stopsSection: some View {
        Section("Route stops") {
            ForEach(Array(navigation.stops.enumerated()), id: \.element.id) { index, stop in
                HStack {
                    Image(systemName: index == navigation.stops.count - 1 ? "flag.checkered" : "\(index + 1).circle.fill")
                        .foregroundColor(Theme.apexRed)
                    Text(stop.name).lineLimit(1)
                    Spacer()
                    Button(role: .destructive) { navigation.removeStop(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button { addingWaypoint = true; query = ""; results = [] } label: {
                Label("Add stop before destination", systemImage: "plus.circle")
            }
            .disabled(navigation.stops.count >= 8)

            if googleStatus == .ready {
                startButton("Start with Google Maps")
            } else {
                Button {
                    guard let origin else { return }
                    Task { await navigation.calculateRoutes(from: origin) }
                } label: {
                    Label(origin == nil ? "Waiting for current location…" : "Calculate route",
                          systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                .disabled(origin == nil || navigation.status == .calculating)
                if let error = navigation.lastError {
                    Text(error).font(.system(size: 12)).foregroundColor(Theme.apexRed)
                }
            }
        }
    }

    private var routesSection: some View {
        Section("Routes (Apple Maps)") {
            ForEach(Array(navigation.candidateRoutes.enumerated()), id: \.element.id) { index, route in
                Button { navigation.selectedRouteIndex = index } label: {
                    HStack {
                        Image(systemName: index == navigation.selectedRouteIndex ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(Theme.apexRed)
                        VStack(alignment: .leading) {
                            Text(route.name).foregroundColor(Theme.textPrimary).lineLimit(1)
                            Text("\(RideFormat.distance(route.distanceMeters)) · \(Int(route.expectedTravelSeconds / 60)) min")
                                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                            ForEach(route.advisories, id: \.self) {
                                Text($0).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                }
            }
            startButton("Start navigation")
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            onStart()
            dismiss()
        } label: {
            Text(title).font(.system(size: 16, weight: .heavy))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundColor(.white)
                .background(Theme.apexRed)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    private func row(_ d: Destination) -> some View {
        HStack {
            Button { choose(d) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).foregroundColor(Theme.textPrimary).lineLimit(1)
                    if !d.subtitle.isEmpty {
                        Text(d.subtitle).font(.system(size: 12)).foregroundColor(Theme.textSecondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { store.toggleSaved(d) } label: {
                Image(systemName: store.isSaved(d) ? "star.fill" : "star").foregroundColor(Theme.apexRed)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(store.isSaved(d) ? "Remove saved place" : "Save place")
        }
    }

    private func choose(_ d: Destination) {
        if addingWaypoint {
            navigation.addWaypoint(d)
            addingWaypoint = false
        } else {
            navigation.setDestination(d)
        }
        query = ""
        results = []
        if googleStatus != .ready, let origin {
            Task { await navigation.calculateRoutes(from: origin) }
        }
    }

    private func runSearch() async {
        isSearching = true
        results = await navigation.search(query, near: origin)
        isSearching = false
    }
}
