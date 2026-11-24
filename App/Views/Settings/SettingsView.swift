//
//  SettingsView.swift
//  ReTripper
//
//  Settings screen with units preference, app info, and data management.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var dataManager: DataManager
    @State private var showingResetAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SETTINGS")
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                    .foregroundColor(Theme.textPrimary)
                                Text("PREFERENCES & SYSTEM")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .tracking(1.2)
                            }
                            Spacer()
                        }
                        .padding(.top, 8)

                        // Preferences: Distance Units
                        VStack(alignment: .leading, spacing: 14) {
                            Text("PREFERENCES")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            VStack(spacing: 8) {
                                HStack {
                                    Text("Distance Unit")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    Picker("Distance Unit", selection: $dataManager.distanceUnit) {
                                        ForEach(DistanceUnit.allCases, id: \.self) { unit in
                                            Text(unit.label).tag(unit)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(Theme.apexRed)
                                }
                            }
                        }
                        .darkCard(padding: 16)

                        // App Profile & Identity
                        VStack(alignment: .leading, spacing: 12) {
                            Text("PRODUCT IDENTITY")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Theme.surfaceSecondary)
                                        .frame(width: 44, height: 44)
                                    Circle()
                                        .fill(Theme.apexRed)
                                        .frame(width: 14, height: 14)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ReTripper Companion")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(Theme.textPrimary)
                                    Text("Tuned for Royal Enfield Guerrilla 450 Apex Red")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.textSecondary)
                                }
                            }

                            Text("A premium, offline-first companion application engineered with pure black aesthetics, Apex Red accents, and complete user privacy.")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.top, 4)
                        }
                        .darkCard(padding: 16)

                        // Privacy & Architecture
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ARCHITECTURE & PRIVACY")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            SettingsRow(title: "Architecture", value: "Native Swift & SwiftUI")
                            SettingsRow(title: "Platform Target", value: "iOS 17.0+")
                            SettingsRow(title: "Data Storage", value: "Local Device Sandbox")
                            SettingsRow(title: "Cloud & Network", value: "No tracking; maps use Apple/Google")
                            SettingsRow(title: "Version", value: "1.0 (Build 1)")
                        }
                        .darkCard(padding: 16)

                        // Ride Mode reminders & integrations
                        RideSettingsSection(alerts: ContextualAlertManager.shared,
                                            google: GoogleNavigationController.shared)

                        // Data Management
                        VStack(alignment: .leading, spacing: 12) {
                            Text("DATA MANAGEMENT")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            Button(action: { showingResetAlert = true }) {
                                HStack {
                                    Image(systemName: "trash")
                                        .font(.system(size: 14))
                                    Text("Reset All Data to Factory Default")
                                        .font(.system(size: 14, weight: .bold))
                                    Spacer()
                                }
                                .foregroundColor(Theme.apexRed)
                                .padding(12)
                                .background(Theme.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                        .darkCard(padding: 16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Reset All Data?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    dataManager.resetAllData()
                }
            } message: {
                Text("This will clear all logged fuel refills, maintenance records, and rides, restoring the default Guerrilla 450 profile.")
            }
        }
    }
}

struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SettingsView()
        .environmentObject(DataManager.shared)
}

// MARK: - Ride Mode settings

struct RideSettingsSection: View {
    @ObservedObject var alerts: ContextualAlertManager
    @ObservedObject var google: GoogleNavigationController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RIDE MODE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .tracking(1.2)

            Stepper(value: $alerts.serviceIntervalKm, in: 1000...20000, step: 500) {
                SettingsRow(title: "Service reminder every", value: String(format: "%.0f km", alerts.serviceIntervalKm))
            }
            Stepper(value: $alerts.fuelReminderKm, in: 50...600, step: 10) {
                SettingsRow(title: "Fuel stop reminder after", value: String(format: "%.0f km", alerts.fuelReminderKm))
            }
            Text("Reminders use your own service and refuel logs. They never replace the motorcycle's warning lights.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)

            SettingsRow(title: "Google Maps", value: google.status == .ready ? "Ready" : "Not configured")
            Text(google.status.summary)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
            SettingsRow(title: "Spotify", value: "Not configured")
            SettingsRow(title: "Weather advisories", value: "No provider")
            SettingsRow(title: "Vehicle telemetry", value: "Unavailable")
        }
        .darkCard(padding: 16)
        .onAppear { google.refreshStatus() }
    }
}
