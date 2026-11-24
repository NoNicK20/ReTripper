//
//  AddServiceSheet.swift
//  ReTripper
//
//  Modal sheet for logging motorcycle maintenance or service.
//

import SwiftUI

struct AddServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dataManager: DataManager

    @State private var title: String = ""
    @State private var odometerString: String = ""
    @State private var costString: String = ""
    @State private var serviceCenter: String = ""
    @State private var notes: String = ""
    @State private var date: Date = Date()

    private let servicePresets = [
        "First Service (500 km)",
        "Engine Oil & Filter",
        "Chain Clean & Lube",
        "Brake Inspection",
        "Tire Pressure & Wear",
        "General Inspection"
    ]

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
        title.trimmingCharacters(in: .whitespaces).isEmpty || parsedCost == nil || parsedOdometer == nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Presets
                        VStack(alignment: .leading, spacing: 10) {
                            Text("QUICK SERVICE PRESETS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(servicePresets, id: \.self) { preset in
                                        Button(action: { title = preset }) {
                                            Text(preset)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(title == preset ? Theme.textPrimary : Theme.textSecondary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 7)
                                                .background(title == preset ? Theme.apexRed : Theme.surfaceSecondary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        .darkCard(padding: 16)

                        // Service Details
                        VStack(alignment: .leading, spacing: 14) {
                            Text("SERVICE DETAILS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            FormField(
                                label: "Service Title / Description (Required)",
                                placeholder: "e.g. Engine Oil & Filter Change",
                                text: $title
                            )

                            FormField(
                                label: "Odometer (\(dataManager.distanceUnit.shortLabel))",
                                placeholder: String(format: "%.0f", dataManager.motorcycle.currentOdometer),
                                text: $odometerString,
                                keyboardType: .decimalPad
                            )

                            FormField(
                                label: "Total Cost",
                                placeholder: "e.g. 75.00",
                                text: $costString,
                                keyboardType: .decimalPad
                            )

                            FormField(
                                label: "Service Center / Mechanic",
                                placeholder: "e.g. Royal Enfield Authorized Service",
                                text: $serviceCenter
                            )

                            DatePicker("Date", selection: $date, displayedComponents: [.date])
                                .datePickerStyle(.compact)
                                .foregroundColor(Theme.textPrimary)
                                .colorScheme(.dark)
                        }
                        .darkCard(padding: 16)

                        // Notes
                        VStack(alignment: .leading, spacing: 10) {
                            Text("NOTES (OPTIONAL)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            TextField("Parts replaced, oil grade, next recommended interval", text: $notes)
                                .foregroundColor(Theme.textPrimary)
                                .padding(12)
                                .background(Theme.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .darkCard(padding: 16)

                        // Save Button
                        Button(action: saveServiceLog) {
                            Text("Save Service Log")
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
            .navigationTitle("Log Service")
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

    private func saveServiceLog() {
        guard let cost = parsedCost, let odo = parsedOdometer else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else { return }

        let log = MaintenanceLog(
            date: date,
            odometer: odo,
            title: cleanTitle,
            totalCost: cost,
            serviceCenter: serviceCenter.trimmingCharacters(in: .whitespaces),
            notes: notes.trimmingCharacters(in: .whitespaces)
        )

        dataManager.addMaintenanceLog(log)
        dismiss()
    }
}
