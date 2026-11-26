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
    @State private var showingEditMotorcycle = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        // Header
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SETTINGS")
                                    .font(.system(size: 22, weight: .black, design: .rounded))
                                    .foregroundColor(Theme.textPrimary)
                                Text("PREFERENCES & SYSTEM")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .tracking(1.2)
                            }
                            Spacer()
                        }
                        .padding(.top, 8)

                        // Motorcycle profile (odometer is set here — the Tripper
                        // Dash link can't read it from the bike).
                        VStack(alignment: .leading, spacing: 12) {
                            Text("MOTORCYCLE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            SettingsRow(title: "Bike", value: dataManager.motorcycle.displayName)
                            SettingsRow(title: "Odometer",
                                        value: String(format: "%.0f %@", dataManager.displayOdometer, dataManager.distanceUnit.shortLabel))

                            Button(action: { showingEditMotorcycle = true }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Edit Motorcycle Profile")
                                        .font(.system(size: 14, weight: .bold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                .foregroundColor(Theme.apexRed)
                                .padding(12)
                                .background(Theme.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                        .darkCard(padding: 14)

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
                        .darkCard(padding: 14)

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
                        .darkCard(padding: 14)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingEditMotorcycle) {
                EditMotorcycleSheet()
            }
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
    /// Dash map orientation: heading-up (rotates to travel direction) vs
    /// north-up (fixed, readable street names). Default north-up.
    @AppStorage(DashMapDefaults.headingUpKey) private var dashHeadingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RIDE MODE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .tracking(1.2)

            Toggle(isOn: $dashHeadingUp) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dash map heading-up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text(dashHeadingUp
                         ? "Map turns to your direction. Street names rotate with it."
                         : "North stays up. Street names stay upright and readable.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .tint(Theme.apexRed)

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
            SettingsRow(title: "Spotify", value: AppSecretsConfiguration.spotifyClientID != nil ? "Pick it on the Ride music card" : "Not configured")
            SettingsRow(title: "Weather advisories", value: "No provider")
            SettingsRow(title: "Vehicle telemetry", value: "Unavailable")
        }
        .darkCard(padding: 16)
        .onAppear { google.refreshStatus() }
    }
}
