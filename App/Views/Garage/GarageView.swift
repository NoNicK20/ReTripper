//
//  GarageView.swift
//  ReTripper
//
//  Garage screen showing motorcycle profile and editable vehicle information.
//

import SwiftUI

struct GarageView: View {
    @EnvironmentObject private var dataManager: DataManager
    @EnvironmentObject private var connectionManager: DashboardConnectionManager
    @State private var showingEditSheet = false
    @State private var showingConnectSheet = false

    private var totalFuelLiters: Double {
        dataManager.fuelLogs.reduce(0) { $0 + $1.liters }
    }

    private var totalExpenses: Double {
        let fuel = dataManager.fuelLogs.reduce(0) { $0 + $1.totalCost }
        let service = dataManager.maintenanceLogs.reduce(0) { $0 + $1.totalCost }
        return fuel + service
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header & Edit Button
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GARAGE")
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                    .foregroundColor(Theme.textPrimary)
                                Text("MOTORCYCLE PROFILE")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .tracking(1.2)
                            }

                            Spacer()

                            Button(action: { showingEditSheet = true }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Edit")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.surfaceElevated)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Theme.borderSubtle, lineWidth: 1)
                                )
                            }
                        }
                        .padding(.top, 8)

                        // Main Showcase Card
                        MotorcycleCard(motorcycle: dataManager.motorcycle)

                        // Vehicle Identification & Odometer Grid
                        VStack(alignment: .leading, spacing: 12) {
                            Text("VEHICLE IDENTIFICATION")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            VStack(spacing: 10) {
                                DetailRow(
                                    label: "Registration / Plate",
                                    value: dataManager.motorcycle.registrationNumber.isEmpty ? "Not configured" : dataManager.motorcycle.registrationNumber,
                                    isSet: !dataManager.motorcycle.registrationNumber.isEmpty
                                )
                                DetailRow(
                                    label: "Chassis / VIN",
                                    value: dataManager.motorcycle.vin.isEmpty ? "Not configured" : dataManager.motorcycle.vin,
                                    isSet: !dataManager.motorcycle.vin.isEmpty
                                )
                                DetailRow(
                                    label: "Fuel Tank Capacity",
                                    value: String(format: "%.1f Liters", dataManager.motorcycle.fuelCapacityLiters),
                                    isSet: true
                                )
                                DetailRow(
                                    label: "Model Year",
                                    value: String(dataManager.motorcycle.year),
                                    isSet: true
                                )
                                DetailRow(
                                    label: "Current Odometer",
                                    value: String(format: "%.0f %@", dataManager.motorcycle.currentOdometer, dataManager.distanceUnit.shortLabel),
                                    isSet: true,
                                    accentColor: Theme.apexRed
                                )
                                DetailRow(
                                    label: "Tripper Dash Link",
                                    value: connectionManager.state.displayTitle,
                                    isSet: connectionManager.isConnected,
                                    accentColor: connectionManager.isConnected ? Theme.apexRed : nil
                                )

                                Button(action: { showingConnectSheet = true }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.system(size: 11, weight: .bold))
                                        Text(connectionManager.isConnected ? "Manage Tripper Connection" : "Connect Tripper Dash")
                                            .font(.system(size: 12, weight: .bold))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                    .foregroundColor(Theme.apexRed)
                                    .padding(.top, 4)
                                }
                            }
                        }
                        .darkCard(padding: 16)

                        // Lifetime Stats
                        VStack(alignment: .leading, spacing: 12) {
                            Text("LIFETIME SUMMARY")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            HStack(spacing: 10) {
                                StatBox(
                                    title: "TOTAL FUEL",
                                    value: String(format: "%.1f L", totalFuelLiters),
                                    caption: "\(dataManager.fuelLogs.count) fill-ups"
                                )

                                StatBox(
                                    title: "SERVICES",
                                    value: String(dataManager.maintenanceLogs.count),
                                    caption: "logged visits"
                                )

                                StatBox(
                                    title: "TOTAL COST",
                                    value: String(format: "%.0f", totalExpenses),
                                    caption: "fuel & service"
                                )
                            }
                        }
                        .darkCard(padding: 16)

                        // Guerrilla 450 Technical Reference
                        VStack(alignment: .leading, spacing: 12) {
                            Text("FACTORY SPECIFICATIONS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            VStack(spacing: 8) {
                                SpecItem(label: "Engine", value: "Sherpa 452cc DOHC Liquid-Cooled")
                                SpecItem(label: "Max Power", value: "40.02 PS (29.44 kW) @ 8,000 RPM")
                                SpecItem(label: "Max Torque", value: "40 Nm @ 5,500 RPM")
                                SpecItem(label: "Transmission", value: "6-Speed with Assist & Slipper Clutch")
                                SpecItem(label: "Tires", value: "120/70-17 (Front), 160/60-17 (Rear)")
                                SpecItem(label: "Seat Height", value: "780 mm")
                                SpecItem(label: "Kerb Weight", value: "185 kg")
                            }
                        }
                        .darkCard(padding: 16)

                        if !dataManager.motorcycle.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("RIDER NOTES")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                Text(dataManager.motorcycle.notes)
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .darkCard(padding: 16)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingEditSheet) {
                EditMotorcycleSheet()
            }
            .sheet(isPresented: $showingConnectSheet) {
                DashboardConnectSheet()
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    let isSet: Bool
    var accentColor: Color? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(accentColor ?? (isSet ? Theme.textPrimary : Theme.textTertiary))
        }
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundColor(Theme.textPrimary)
            Text(caption)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SpecItem: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 95, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }
}

struct EditMotorcycleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dataManager: DataManager

    @State private var make: String = ""
    @State private var model: String = ""
    @State private var edition: String = ""
    @State private var year: String = ""
    @State private var registration: String = ""
    @State private var vin: String = ""
    @State private var odometer: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("MOTORCYCLE PROFILE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            FormField(label: "Manufacturer", placeholder: "Royal Enfield", text: $make)
                            FormField(label: "Model", placeholder: "Guerrilla 450", text: $model)
                            FormField(label: "Edition / Variant", placeholder: "Apex Red", text: $edition)
                            FormField(label: "Year", placeholder: "2024", text: $year, keyboardType: .numberPad)
                        }
                        .darkCard(padding: 16)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("IDENTIFICATION")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            FormField(label: "Registration / License Plate", placeholder: "e.g. KA 01 AB 1234", text: $registration)
                            FormField(label: "VIN / Chassis Number", placeholder: "e.g. ME3...", text: $vin)
                            FormField(label: "Current Odometer (\(dataManager.distanceUnit.shortLabel))", placeholder: "0", text: $odometer, keyboardType: .decimalPad)
                        }
                        .darkCard(padding: 16)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("RIDER NOTES")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            TextField("Custom modifications, accessories, service reminders", text: $notes)
                                .foregroundColor(Theme.textPrimary)
                                .padding(12)
                                .background(Theme.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .darkCard(padding: 16)

                        Button(action: saveChanges) {
                            Text("Save Changes")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.apexRed)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Edit Motorcycle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .onAppear {
            let m = dataManager.motorcycle
            make = m.make
            model = m.model
            edition = m.edition
            year = String(m.year)
            registration = m.registrationNumber
            vin = m.vin
            odometer = String(format: "%.0f", m.currentOdometer)
            notes = m.notes
        }
    }

    private func saveChanges() {
        var updated = dataManager.motorcycle
        let cleanMake = make.trimmingCharacters(in: .whitespaces)
        let cleanModel = model.trimmingCharacters(in: .whitespaces)
        let cleanEdition = edition.trimmingCharacters(in: .whitespaces)

        if !cleanMake.isEmpty { updated.make = cleanMake }
        if !cleanModel.isEmpty { updated.model = cleanModel }
        if !cleanEdition.isEmpty { updated.edition = cleanEdition }
        
        if let y = Int(year.trimmingCharacters(in: .whitespaces)), y >= 1900 && y <= 2100 {
            updated.year = y
        }
        
        updated.registrationNumber = registration.trimmingCharacters(in: .whitespaces)
        updated.vin = vin.trimmingCharacters(in: .whitespaces)
        
        let cleanOdo = odometer.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let o = Double(cleanOdo), o >= 0 {
            updated.currentOdometer = o
        }
        
        updated.notes = notes.trimmingCharacters(in: .whitespaces)

        dataManager.updateMotorcycle(updated)
        dismiss()
    }
}

#Preview {
    GarageView()
        .environmentObject(DataManager.shared)
        .environmentObject(DashboardConnectionManager.shared)
}
