//
//  RideInstrumentViews.swift
//  ReTripper
//
//  Ride-mode instruments: trip meter, digital compass, now-playing card,
//  alert overlay and audio guidance controls. Large, high-contrast controls
//  with minimal animation for use while riding.
//

import SwiftUI
import MediaPlayer
import AVKit

// MARK: - Shared styling

struct RideLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.textTertiary)
            .tracking(1.2)
    }
}

struct RideMetric: View {
    let label: String
    let value: String
    var unit: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RideLabel(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BigRideButton: View {
    let title: String
    let symbol: String
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18, weight: .bold))
                Text(title).font(.system(size: 15, weight: .heavy))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(filled ? Theme.apexRed : Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trip meter

struct TripMeterPanel: View {
    @ObservedObject var tripMeter: TripMeterManager
    let unit: DistanceUnit
    @State private var confirmReset: TripSlot?

    private func distance(_ km: Double) -> String {
        String(format: "%.2f", unit == .miles ? km / 1.609344 : km)
    }

    private func speed(_ kmh: Double) -> String {
        String(format: "%.0f", unit == .miles ? kmh / 1.609344 : kmh)
    }

    private var speedUnit: String { unit == .miles ? "mph" : "km/h" }

    var body: some View {
        let m = tripMeter.metrics(for: tripMeter.displayedSlot)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Trip", selection: $tripMeter.displayedSlot) {
                    ForEach(TripSlot.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()

                Button("Reset") { confirmReset = tripMeter.displayedSlot }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.apexRed)
                    .frame(minWidth: 56, minHeight: 44)
            }

            HStack(spacing: 12) {
                RideMetric(label: "DISTANCE", value: distance(m.distanceKm), unit: unit.shortLabel)
                RideMetric(label: "AVG MOVING", value: speed(m.averageMovingSpeedKmh), unit: speedUnit)
            }
            HStack(spacing: 12) {
                RideMetric(label: "TOTAL TIME", value: TripMetrics.formatDuration(m.elapsedSeconds))
                RideMetric(label: "MOVING", value: TripMetrics.formatDuration(m.movingSeconds))
                RideMetric(label: "STOPPED", value: TripMetrics.formatDuration(m.stoppedSeconds))
            }
            HStack(spacing: 12) {
                RideMetric(label: "MAX SPEED", value: speed(m.maxSpeedKmh), unit: speedUnit)
                RideMetric(label: "ELEV. GAIN",
                           value: m.elevationReliable ? String(format: "%.0f", m.elevationGainMeters) : "—",
                           unit: m.elevationReliable ? "m" : "")
            }

            Text(tripMeter.displayedSlot == .tripA
                 ? "Trip A measures this ride. PHONE GPS — not motorcycle telemetry."
                 : "Trip B keeps counting across rides until reset. PHONE GPS — not motorcycle telemetry.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
        }
        .darkCard(padding: 14)
        .confirmationDialog("Reset \(confirmReset?.rawValue ?? "trip")?",
                            isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } }),
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                if let slot = confirmReset { tripMeter.reset(slot) }
                confirmReset = nil
            }
        }
    }
}

// MARK: - Compass

struct DigitalCompassView: View {
    @ObservedObject var compass: CompassManager
    var size: CGFloat = 220

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.surface)
                Circle().stroke(Theme.border, lineWidth: 2)

                // Dial rotates so the current heading is at the top.
                ZStack {
                    ForEach(0..<72, id: \.self) { i in
                        let major = i % 9 == 0
                        Rectangle()
                            .fill(major ? Theme.textPrimary : Theme.textTertiary)
                            .frame(width: major ? 3 : 1, height: major ? 14 : 7)
                            .offset(y: -size / 2 + 12)
                            .rotationEffect(.degrees(Double(i) * 5))
                    }
                    ForEach(Array(CompassMath.eightPointNames.enumerated()), id: \.offset) { index, name in
                        Text(name)
                            .font(.system(size: index % 2 == 0 ? 20 : 12, weight: .heavy, design: .rounded))
                            .foregroundColor(name == "N" ? Theme.apexRed : Theme.textPrimary)
                            .rotationEffect(.degrees(-Double(index) * 45 + (compass.displayedHeading ?? 0)))
                            .offset(y: -size / 2 + 38)
                            .rotationEffect(.degrees(Double(index) * 45))
                    }
                }
                .rotationEffect(.degrees(-(compass.displayedHeading ?? 0)))

                // Fixed lubber line.
                Triangle()
                    .fill(Theme.apexRed)
                    .frame(width: 18, height: 16)
                    .offset(y: -size / 2 - 2)

                VStack(spacing: 0) {
                    Text(compass.displayedHeading.map { String(format: "%03.0f°", $0) } ?? "---°")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .monospacedDigit()
                    Text(compass.directionText)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.apexRed)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heading \(compass.directionText)")

            if !compass.sensorAvailable && compass.source == .unavailable {
                Text("No compass sensor on this device. Heading appears from GPS once moving.")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Picker("Reference", selection: $compass.reference) {
                ForEach(CompassReference.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                RideMetric(label: "SOURCE", value: compass.source.rawValue)
                RideMetric(label: "ACCURACY",
                           value: compass.headingAccuracy >= 0 ? String(format: "±%.0f°", compass.headingAccuracy) : "—")
            }
            HStack(spacing: 6) {
                Image(systemName: compass.calibration == .needsCalibration ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundColor(compass.calibration == .needsCalibration ? Theme.apexRed : Theme.textSecondary)
                Text(compass.calibration == .needsCalibration
                     ? "Needs calibration — move the phone in a figure-eight away from the motorcycle."
                     : compass.calibration.rawValue)
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                Spacer()
            }
        }
        .darkCard(padding: 14)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Now playing

struct NowPlayingCard: View {
    @ObservedObject var music: MusicManager

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let art = music.nowPlaying?.artwork {
                    Image(uiImage: art).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: 20)).foregroundColor(Theme.textTertiary)
                }
            }
            .frame(width: 48, height: 48)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                switch music.availability {
                case .available:
                    Text(music.nowPlaying?.title ?? "Nothing playing in \(music.selectedKind.rawValue)")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    Text(music.nowPlaying?.artist ?? music.selectedKind.rawValue)
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary).lineLimit(1)
                case .needsAuthorization:
                    Button("Allow \(music.selectedKind.rawValue) access") {
                        Task { await music.requestAuthorization() }
                    }
                    .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.apexRed)
                case .denied:
                    Text("Media access denied").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.textPrimary)
                    Text("Enable it in iOS Settings ➔ ReTripper.").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                case .notConfigured(let reason):
                    Text("\(music.selectedKind.rawValue) unavailable").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.textPrimary)
                    Text(reason).font(.system(size: 10)).foregroundColor(Theme.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)

            if music.availability.isAvailable {
                mediaButton("backward.fill") { music.previous() }
                mediaButton(music.playbackState == .playing ? "pause.fill" : "play.fill") { music.togglePlayPause() }
                mediaButton("forward.fill") { music.next() }
            }
        }
        .darkCard(padding: 10)
    }

    private func mediaButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 46, height: 46)
                .background(Theme.surfaceElevated)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Alerts

struct RideAlertOverlay: View {
    @ObservedObject var alerts: ContextualAlertManager

    var body: some View {
        if let alert = alerts.top {
            HStack(spacing: 12) {
                Image(systemName: alert.symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(alert.priority >= .warning ? Theme.apexRed : Theme.surfaceElevated)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(.system(size: 16, weight: .heavy)).foregroundColor(Theme.textPrimary).lineLimit(2)
                    Text(alert.message).font(.system(size: 12)).foregroundColor(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button { alerts.dismiss(alert) } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.textSecondary).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss alert")
            }
            .padding(10)
            .background(Theme.surface.opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(alert.priority >= .warning ? Theme.apexRed : Theme.border, lineWidth: 1.5))
            .padding(.horizontal, 12)
            .transition(.opacity)
        }
    }
}

// MARK: - Audio guidance controls

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = UIColor(Theme.apexRed)
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = UIColor(Theme.apexRed)
        picker.tintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct AudioGuidanceSheet: View {
    @ObservedObject var audio: NavigationAudioManager
    @ObservedObject var music: MusicManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            RideLabel(text: "VOICE GUIDANCE")
                            Picker("Mode", selection: $audio.mode) {
                                ForEach(GuidanceMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if audio.externalEngineSpeaks {
                                Text("Google Navigation SDK is speaking directions; ReTripper's own voice stays silent to avoid duplicates.")
                                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                            }
                            BigRideButton(title: "Repeat instruction", symbol: "arrow.counterclockwise") {
                                audio.repeatLastInstruction()
                            }
                            .disabled(audio.lastInstruction == nil)
                        }
                        .darkCard(padding: 14)

                        VStack(alignment: .leading, spacing: 10) {
                            RideLabel(text: "VOICE VOLUME (RELATIVE)")
                            Slider(value: $audio.voiceVolume, in: 0.1...1.0).tint(Theme.apexRed)
                            RideLabel(text: "SYSTEM VOLUME")
                            SystemVolumeSlider().frame(height: 34)
                        }
                        .darkCard(padding: 14)

                        VStack(alignment: .leading, spacing: 10) {
                            RideLabel(text: "AUDIO OUTPUT")
                            HStack {
                                Text(audio.currentOutputName)
                                    .font(.system(size: 15, weight: .bold)).foregroundColor(Theme.textPrimary)
                                Spacer()
                                AudioRoutePicker().frame(width: 44, height: 44)
                            }
                            Text("Pair your Bluetooth helmet headset in iOS Settings, then choose it here. Music is lowered while directions are spoken.")
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                        }
                        .darkCard(padding: 14)

                        VStack(alignment: .leading, spacing: 10) {
                            RideLabel(text: "MUSIC SOURCE")
                            Picker("Music", selection: Binding(get: { music.selectedKind }, set: { music.select($0) })) {
                                ForEach(MusicProviderKind.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Text("Apple Music controls the Music app only. Other apps cannot be controlled by ReTripper.")
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                        }
                        .darkCard(padding: 14)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
