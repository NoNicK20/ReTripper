//
//  EditMotorcycleSheet.swift
//  ReTripper
//
//  Edit the motorcycle profile (name, identification, odometer, notes).
//  Reached from Settings. The odometer is entered here because the Tripper
//  Dash link cannot report it from the bike.
//

import SwiftUI

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
