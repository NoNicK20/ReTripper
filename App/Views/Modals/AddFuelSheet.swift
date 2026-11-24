//
//  AddFuelSheet.swift
//  ReTripper
//
//  Modal sheet for logging a fuel refill.
//

import SwiftUI

struct AddFuelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dataManager: DataManager

    @State private var odometerString: String = ""
    @State private var litersString: String = ""
    @State private var costString: String = ""
    @State private var isFullTank: Bool = true
    @State private var notes: String = ""
    @State private var date: Date = Date()

    private var parsedLiters: Double? {
        let clean = litersString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let val = Double(clean), val > 0 else { return nil }
        return val
    }

    private var parsedCost: Double? {
        let clean = costString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if clean.isEmpty { return 0.0 }
        guard let val = Double(clean), val >= 0 else { return nil }
        return val
    }

    private var parsedOdometer: Double? {
        let clean = odometerString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if clean.isEmpty { return dataManager.motorcycle.currentOdometer }
        guard let val = Double(clean), val >= 0 else { return nil }
        return val
    }

    private var isSaveDisabled: Bool {
        parsedLiters == nil || parsedCost == nil || parsedOdometer == nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Section: Fill-up Details
                        VStack(alignment: .leading, spacing: 14) {
                            Text("FILL-UP DETAILS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            VStack(spacing: 12) {
                                FormField(
                                    label: "Fuel Volume (Liters, Required)",
                                    placeholder: "e.g. 8.5",
                                    text: $litersString,
                                    keyboardType: .decimalPad
                                )

                                FormField(
                                    label: "Odometer (\(dataManager.distanceUnit.shortLabel))",
                                    placeholder: String(format: "%.0f", dataManager.motorcycle.currentOdometer),
                                    text: $odometerString,
                                    keyboardType: .decimalPad
                                )

                                FormField(
                                    label: "Total Cost",
                                    placeholder: "e.g. 24.50",
                                    text: $costString,
                                    keyboardType: .decimalPad
                                )

                                Toggle(isOn: $isFullTank) {
                                    Text("Full Tank Refill")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                }
                                .tint(Theme.apexRed)
                                .padding(.vertical, 4)

                                DatePicker("Date", selection: $date, displayedComponents: [.date])
                                    .datePickerStyle(.compact)
                                    .foregroundColor(Theme.textPrimary)
                                    .colorScheme(.dark)
                            }
                        }
                        .darkCard(padding: 16)

                        // Section: Notes
                        VStack(alignment: .leading, spacing: 10) {
                            Text("NOTES (OPTIONAL)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            TextField("Station, octane grade, or ride conditions", text: $notes)
                                .foregroundColor(Theme.textPrimary)
                                .padding(12)
                                .background(Theme.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .darkCard(padding: 16)

                        // Save Button
                        Button(action: saveFuelLog) {
                            Text("Save Fuel Log")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.apexRed)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                        }
                        .disabled(isSaveDisabled)
                        .opacity(isSaveDisabled ? 0.45 : 1.0)
                        .padding(.top, 8)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Log Fuel Refill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .onAppear {
            if dataManager.motorcycle.currentOdometer > 0 {
                odometerString = String(format: "%.0f", dataManager.motorcycle.currentOdometer)
            }
        }
    }

    private func saveFuelLog() {
        guard let liters = parsedLiters, let cost = parsedCost, let odo = parsedOdometer else {
            return
        }

        let log = FuelLog(
            date: date,
            odometer: odo,
            liters: liters,
            totalCost: cost,
            isFullTank: isFullTank,
            notes: notes
        )

        dataManager.addFuelLog(log)
        dismiss()
    }
}

struct FormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
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
}
