//
//  RideNavigationViews.swift
//  ReTripper
//
//  Google Maps map surface (or a clear configuration message when Google Maps
//  is not configured), the large turn-by-turn panel, the compact direction card
//  shown over the map, and Google Places destination search.
//

import SwiftUI
import CoreLocation

// MARK: - Map surface

/// The real Google Maps view, rendered natively. Never substitutes another map.
struct GoogleMapSurface: View {
    @ObservedObject var google: GoogleNavigationController
    let padding: UIEdgeInsets

    var body: some View {
        switch google.status {
        case .ready, .termsNotAccepted:
            ZStack {
                GoogleMapHostView(controller: google, padding: padding)
                if google.status == .termsNotAccepted {
                    VStack {
                        Spacer()
                        GoogleMapsNotice(
                            title: "Google navigation terms",
                            message: "Google requires you to accept its navigation terms before turn-by-turn guidance can start.",
                            buttonTitle: "Review terms",
                            action: { google.requestTermsAcceptance() })
                            .padding(.bottom, padding.bottom + 8)
                            .padding(.horizontal, 16)
                    }
                }
            }
        case .missingAPIKey:
            ZStack {
                Theme.background
                GoogleMapsNotice(
                    title: "Google Maps is not configured",
                    message: "This build of ReTripper has no Google Maps API key, so the map cannot be shown. Add the key as the GOOGLE_MAPS_API_KEY GitHub secret (or in Config/Secrets.xcconfig) and rebuild. See GOOGLE_MAPS_SETUP.md.",
                    buttonTitle: nil,
                    action: {})
                    .padding(.horizontal, 20)
            }
        }
    }
}

struct GoogleMapsNotice: View {
    let title: String
    let message: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(Theme.apexRed)
            Text(title)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle {
                BigRideButton(title: buttonTitle, symbol: "checkmark.shield", filled: true, action: action)
            }
        }
        .padding(18)
        .background(Theme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Direction card over the map

struct DirectionCard: View {
    @ObservedObject var navigation: NavigationManager

    var body: some View {
        if let p = navigation.progress, navigation.status.isActive {
            HStack(spacing: 12) {
                Image(systemName: p.nextManeuver.symbolName)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(Theme.apexRed)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(RideFormat.distance(p.distanceToNextManeuverMeters))
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .monospacedDigit()
                    Text(p.nextInstruction)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.black.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .accessibilityElement(children: .combine)
        } else if navigation.status == .rerouting {
            statusPill("Rerouting…")
        } else if navigation.status == .calculating {
            statusPill("Google is calculating routes…")
        } else if navigation.status == .preview {
            statusPill("Routes shown on the map — tap Start")
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .heavy))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.9)).clipShape(Capsule())
    }
}

/// Remaining distance + ETA + trip distance strip shown over the map.
struct RouteSummaryStrip: View {
    @ObservedObject var navigation: NavigationManager
    @ObservedObject var tripMeter: TripMeterManager
    let unit: DistanceUnit

    var body: some View {
        HStack(spacing: 10) {
            if let p = navigation.progress, navigation.status.isActive {
                RideMetric(label: "REMAINING", value: RideFormat.distance(p.remainingDistanceMeters))
                RideMetric(label: "ETA", value: p.remainingSeconds > 0 ? RideFormat.clock(p.eta) : "—")
            }
            let km = tripMeter.tripA.metrics.distanceKm
            RideMetric(label: "TRIP A", value: String(format: "%.1f", unit == .miles ? km / 1.609344 : km), unit: unit.shortLabel)
            RideMetric(label: "MOVING", value: TripMetrics.formatDuration(tripMeter.tripA.metrics.movingSeconds))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }
}

// MARK: - Turn-by-turn panel

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
                    waiting("Waiting for Google to start guidance…")
                }
            case .arrived:
                waiting("Arrived at \(navigation.stops.last?.name ?? "destination")", symbol: "flag.checkered")
            case .calculating:
                waiting("Google is calculating routes…", symbol: "hourglass")
            case .preview:
                waiting("Route ready. Tap Start to begin live guidance.", symbol: "arrow.triangle.turn.up.right.diamond")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activeGuidance(_ p: RouteProgress) -> some View {
        VStack(spacing: 14) {
            if navigation.status == .rerouting {
                Text("REROUTING…")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.apexRed).clipShape(Capsule())
            }
            Spacer(minLength: 0)
            Image(systemName: p.nextManeuver.symbolName)
                .font(.system(size: 110, weight: .heavy))
                .foregroundColor(Theme.textPrimary)
                .frame(maxHeight: 150)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(p.nextInstruction)
            Text(RideFormat.distance(p.distanceToNextManeuverMeters))
                .font(.system(size: 60, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.apexRed)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(p.nextInstruction)
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if let road = p.nextRoadName {
                Text(road.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ProgressView(value: p.fractionComplete).tint(Theme.apexRed)
            HStack(spacing: 12) {
                RideMetric(label: "REMAINING", value: RideFormat.distance(p.remainingDistanceMeters))
                RideMetric(label: "ETA", value: p.remainingSeconds > 0 ? RideFormat.clock(p.eta) : "—")
            }
            Text("Live guidance · \(navigation.engineName)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(16)
    }

    private func waiting(_ text: String, symbol: String = "location.circle") -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 54)).foregroundColor(Theme.textTertiary)
            Text(text).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Destination search (Google Places autocomplete)

struct DestinationSearchSheet: View {
    @ObservedObject var navigation: NavigationManager
    @ObservedObject var store: DestinationStore
    @ObservedObject var google: GoogleNavigationController
    let origin: CLLocationCoordinate2D?
    let onPreview: () -> Void
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Destination] = []
    @State private var isSearching = false
    @State private var addingWaypoint = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    if google.status != .ready {
                        Section {
                            Text(google.status.summary).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                            if google.status == .termsNotAccepted {
                                Button("Review Google navigation terms") { google.requestTermsAcceptance() }
                            }
                        }
                    }

                    if !navigation.stops.isEmpty { stopsSection }

                    if isSearching {
                        Section { ProgressView().frame(maxWidth: .infinity) }
                    }
                    if !results.isEmpty {
                        Section {
                            ForEach(results) { row($0) }
                        } header: {
                            Text("Results")
                        } footer: {
                            googleAttribution
                        }
                    }
                    if let error = navigation.lastError, !query.isEmpty {
                        Section { Text(error).font(.system(size: 12)).foregroundColor(Theme.apexRed) }
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
                            Text("Supports Google Maps and Apple Maps links with coordinates, geo: links and retripper:// links.")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: addingWaypoint ? "Add a stop" : "Search places with Google")
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            .navigationTitle(addingWaypoint ? "Add Stop" : "Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Required attribution for Google Places results shown off a Google map.
    private var googleAttribution: some View {
        HStack {
            Spacer()
            Text("Google Maps")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
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
                    .accessibilityLabel("Remove stop")
                }
            }
            Button { addingWaypoint = true; query = ""; results = [] } label: {
                Label("Add stop before destination", systemImage: "plus.circle")
            }
            .disabled(navigation.stops.count >= 8)

            actionButton("Show routes on map", filled: false) {
                onPreview()
                dismiss()
            }
            .disabled(google.status != .ready)
            actionButton("Start navigation", filled: true) {
                onStart()
                dismiss()
            }
            .disabled(google.status != .ready)
        }
    }

    private func actionButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .heavy))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundColor(.white)
                .background(filled ? Theme.apexRed : Theme.surfaceElevated)
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
    }

    /// Debounced autocomplete as the rider types.
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = await navigation.search(trimmed, near: origin)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
