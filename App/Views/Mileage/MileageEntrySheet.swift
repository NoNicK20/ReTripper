//
//  MileageEntrySheet.swift
//  ReTripper
//
//  Logs a fuel fill for the Mileage tab. Enter any two of litres, price per
//  litre and total cost and the third fills in automatically. A "full tank"
//  tick lets the Mileage tab calculate tank-to-tank economy.
//

import SwiftUI

struct MileageEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dataManager: DataManager

    @State private var odometerString: String = ""
    @State private var priceString: String = ""      // price per litre
    @State private var litersString: String = ""
    @State private var costString: String = ""       // total cost
    @State private var isFullTank: Bool = true
    @State private var notes: String = ""
    @State private var date: Date = Date()

    /// Which of litres / cost the rider last typed, so price changes recompute
    /// the right one.
    private enum Field { case liters, cost }
    @State private var lastEdited: Field = .liters
    /// The last value we wrote into a field ourselves, so our own write doesn't
    /// look like the rider typing (which would ping-pong the two fields).
    @State private var programmatic: String?

    private var parsedLiters: Double? { Self.number(litersString) }
    private var parsedCost: Double? { costString.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : Self.number(costString) }
    private var parsedPrice: Double? { priceString.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.number(priceString) }
    private var parsedOdometer: Double? {
        let clean = odometerString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if clean.isEmpty { return dataManager.motorcycle.currentOdometer }
        guard let val = Double(clean), val >= 0 else { return nil }
        return val
    }

    private var isSaveDisabled: Bool {
        guard let liters = parsedLiters, liters > 0 else { return true }
        return parsedOdometer == nil || parsedCost == nil
    }

    private var unit: String { dataManager.distanceUnit.shortLabel }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("FILL-UP DETAILS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            VStack(spacing: 12) {
                                FormField(
                                    label: "Current Odometer (\(unit))",
                                    placeholder: String(format: "%.0f", dataManager.motorcycle.currentOdometer),
                                    text: $odometerString,
                                    keyboardType: .decimalPad
                                )

                                FormField(
                                    label: "Petrol Price (₹ per litre)",
                                    placeholder: "e.g. 105.50",
                                    text: $priceString,
                                    keyboardType: .decimalPad
                                )

                                FormField(
                                    label: "Petrol Filled (litres)",
                                    placeholder: "e.g. 8.5",
                                    text: $litersString,
                                    keyboardType: .decimalPad
                                )

                                FormField(
                                    label: "Total Paid (₹)",
                                    placeholder: "e.g. 896.75",
                                    text: $costString,
                                    keyboardType: .decimalPad
                                )

                                Text("Enter petrol price with either litres or total — the other fills in automatically.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)

                                Toggle(isOn: $isFullTank) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Full Tank")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(Theme.textPrimary)
                                        Text("Tick to measure tank-to-tank mileage")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textTertiary)
                                    }
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

                        Button(action: save) {
                            Text("Save Fill")
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
            .navigationTitle("Log Fuel Fill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .onChange(of: litersString) { _, newVal in
                if newVal == programmatic { programmatic = nil; return }
                lastEdited = .liters
                syncDerived()
            }
            .onChange(of: costString) { _, newVal in
                if newVal == programmatic { programmatic = nil; return }
                lastEdited = .cost
                syncDerived()
            }
            .onChange(of: priceString) { _, _ in syncDerived() }
        }
        .onAppear {
            if dataManager.motorcycle.currentOdometer > 0 {
                odometerString = String(format: "%.0f", dataManager.motorcycle.currentOdometer)
            }
        }
    }

    /// Keep litres and total in step with the price, recomputing whichever the
    /// rider didn't just type.
    private func syncDerived() {
        guard let price = parsedPrice, price > 0 else { return }
        switch lastEdited {
        case .liters:
            guard let l = Self.number(litersString), l > 0 else { return }
            let v = Self.format(FuelEntryMath.totalCost(liters: l, pricePerLiter: price))
            programmatic = v
            costString = v
        case .cost:
            guard let c = Self.number(costString), c > 0 else { return }
            let v = Self.format(FuelEntryMath.liters(totalCost: c, pricePerLiter: price))
            programmatic = v
            litersString = v
        }
    }

    private func save() {
        guard let liters = parsedLiters, liters > 0,
              let odo = parsedOdometer, let cost = parsedCost else { return }
        let log = FuelLog(
            date: date,
            odometer: odo,
            liters: liters,
            totalCost: cost,
            isFullTank: isFullTank,
            notes: notes.trimmingCharacters(in: .whitespaces),
            pricePerLiter: parsedPrice
        )
        dataManager.addFuelLog(log)
        dismiss()
    }

    private static func number(_ s: String) -> Double? {
        let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let val = Double(clean), val >= 0 else { return nil }
        return val
    }

    private static func format(_ v: Double) -> String { String(format: "%.2f", v) }
}
