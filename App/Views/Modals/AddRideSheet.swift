//
//  AddRideSheet.swift
//  ReTripper
//
//  Modal sheet for logging a manual ride record.
//

import SwiftUI

struct AddRideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dataManager: DataManager

    @State private var title: String = ""
    @State private var distanceString: String = ""
    @State private var durationString: String = ""
    @State private var endingOdometerString: String = ""
    @State private var notes: String = ""
    @State private var date: Date = Date()

    private let routePresets = [
        "Morning Commute",
        "Weekend Canyon Run",
        "Highway Cruise",
        "City Ride",
        "Night Ride"
    ]

    private var parsedDistance: Double? {
        let clean = distanceString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if clean.isEmpty { return nil }
        guard let val = Double(clean), val > 0 else { return nil }
        return val
    }

    private var parsedDuration: Int? {
        let clean = durationString.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { return 0 }
        guard let val = Int(clean), val >= 0 else { return nil }
        return val
    }

    private var parsedEndingOdometer: Double? {
        let clean = endingOdometerString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if clean.isEmpty { return 0.0 }
        guard let val = Double(clean), val >= 0 else { return nil }
        return val
    }

    private var isSaveDisabled: Bool {
        if parsedDuration == nil || parsedEndingOdometer == nil { return true }
        let hasValidDist = (parsedDistance ?? 0) > 0
        let hasValidEndingOdo = (parsedEndingOdometer ?? 0) > dataManager.motorcycle.currentOdometer
        return !(hasValidDist || hasValidEndingOdo)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Presets
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ROUTE PRESETS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(routePresets, id: \.self) { preset in
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

                        // Ride Details
                        VStack(alignment: .leading, spacing: 14) {
                            Text("RIDE DETAILS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            FormField(
                                label: "Ride Title / Destination",
                                placeholder: "e.g. Mountain Pass Run",
                                text: $title
                            )

                            FormField(
                                label: "Distance (\(dataManager.distanceUnit.shortLabel), Required)",
                                placeholder: "e.g. 45.0",
                                text: $distanceString,
                                keyboardType: .decimalPad
                            )

                            FormField(
                                label: "Duration (Minutes)",
                                placeholder: "e.g. 60",
                                text: $durationString,
                                keyboardType: .numberPad
                            )

                            FormField(
                                label: "Ending Odometer (\(dataManager.distanceUnit.shortLabel), Optional)",
                                placeholder: String(format: "%.0f", dataManager.motorcycle.currentOdometer),
                                text: $endingOdometerString,
                                keyboardType: .decimalPad
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

                            TextField("Weather, road conditions, rider observations", text: $notes)
                                .foregroundColor(Theme.textPrimary)
                                .padding(12)
                                .background(Theme.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .darkCard(padding: 16)

                        // Save Button
                        Button(action: saveRideLog) {
                            Text("Save Ride Record")
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
            .navigationTitle("Record Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    private func saveRideLog() {
        guard let duration = parsedDuration else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let finalTitle = cleanTitle.isEmpty ? "Manual Ride" : cleanTitle
        var dist = parsedDistance ?? 0.0
        let endingOdo = parsedEndingOdometer ?? 0.0

        if dist <= 0 && endingOdo > dataManager.motorcycle.currentOdometer {
            dist = endingOdo - dataManager.motorcycle.currentOdometer
        }

        guard dist > 0 || endingOdo > dataManager.motorcycle.currentOdometer else { return }

        let log = RideLog(
            date: date,
            title: finalTitle,
            distance: dist,
            durationMinutes: duration,
            endingOdometer: endingOdo,
            notes: notes.trimmingCharacters(in: .whitespaces)
        )

        dataManager.addRideLog(log)
        dismiss()
    }
}
